import 'dart:async';
import 'dart:convert';

import 'dart:io';
import 'dart:typed_data';

import '../crypto/identity_store.dart';
import '../diagnostics/event_log.dart';
import 'chat_frames.dart';
import 'file_storage.dart';

/// Where a message is. Outgoing: [sending] until stored on the other device
/// ([delivered]), [queued] in the client outbox waiting to send when online,
/// [read] when viewed by the recipient, or [notSent] when the session ended first.
/// Incoming: [received].
enum ChatState { sending, delivered, notSent, received, queued, read }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.contactId,
    required this.outgoing,
    required this.ts,
    required this.text,
    required this.state,
    this.reason,
    this.read = true,
    this.fileId,
    this.fileName,
    this.fileSize,
    this.fileMime,
    this.fileSha256,
    this.fileStatus,
    this.filePath,
    this.fileKey,
    this.arrivedAt,
    this.voiceNote = false,
    this.replyTo,
    this.reactions = const {},
    this.editedAt,
    this.deletedForAll = false,
    this.forwarded = false,
  });

  /// 16 random bytes, unpadded base64url. The same on both devices.
  final String id;

  /// The other person's Sotto ID.
  final String contactId;

  final bool outgoing;

  /// The sender's clock, in milliseconds since the Unix epoch.
  final int ts;

  final String text;
  final ChatState state;

  /// Why the message was not sent: the chat's reason, such as 'no-answer'.
  /// Set only while [state] is [ChatState.notSent].
  final String? reason;

  /// Whether the message has been viewed. Outgoing messages are always true.
  /// Incoming messages start false until the chat is opened.
  final bool read;

  /// If this message represents a file transfer, its metadata.
  final String? fileId;
  final String? fileName;
  final int? fileSize;
  final String? fileMime;
  final String? fileSha256;
  final String? fileStatus;

  /// Where the received file is kept (see [ReceivedFileStore]).
  final String? filePath;

  /// The key that opens the file at [filePath]. It lives in this record, so
  /// deleting the message also makes the file unreadable.
  final String? fileKey;

  /// When an incoming message arrived on this device, in milliseconds since
  /// the epoch. Disappearing messages expire from this time, so a sender's
  /// clock cannot keep a message or purge it on arrival. Null for outgoing
  /// messages (their [ts] is this device's clock).
  final int? arrivedAt;

  /// Whether the file is a voice note: offered as one, and played in the
  /// bubble. A file that is only audio is an ordinary file.
  final bool voiceNote;

  /// The message this one replies to: its id and a copy of its text, so the
  /// quote still shows when the original is gone. Null for no reply.
  final ChatReply? replyTo;

  /// Reactions to this message, one emoji per person: "me" for this device's
  /// owner, "peer" for the contact. A person with no reaction has no key.
  final Map<String, String> reactions;

  /// When the text was last edited, in milliseconds since the epoch (the
  /// sender's clock for an edit by the contact). Null if never edited. No
  /// earlier text is kept.
  final int? editedAt;

  /// Whether the message was deleted for everyone. Its text is then empty, and
  /// the record is kept.
  final bool deletedForAll;

  /// Whether the text was forwarded from another chat.
  final bool forwarded;

  bool get isAttachment => fileName != null;

  /// This message's time on this device: [ts] for outgoing messages, and
  /// [arrivedAt] for incoming ones. It judges when the message expires, and the
  /// chat list and search order by it, so a peer's clock cannot change either.
  int get clockMs => outgoing ? ts : (arrivedAt ?? ts);

  /// The same message in another state. A reason is kept only when given.
  ChatMessage withState(ChatState next, {String? reason}) => ChatMessage(
    id: id,
    contactId: contactId,
    outgoing: outgoing,
    ts: ts,
    text: text,
    state: next,
    reason: reason,
    read: read,
    fileId: fileId,
    fileName: fileName,
    fileSize: fileSize,
    fileMime: fileMime,
    fileSha256: fileSha256,
    fileStatus: fileStatus,
    filePath: filePath,
    fileKey: fileKey,
    arrivedAt: arrivedAt,
    voiceNote: voiceNote,
    replyTo: replyTo,
    reactions: reactions,
    editedAt: editedAt,
    deletedForAll: deletedForAll,
    forwarded: forwarded,
  );

  /// The same message with [who]'s reaction set to [emoji]. [who] is "me" or
  /// "peer". An empty emoji removes the reaction.
  ChatMessage withReaction(String who, String emoji) {
    final next = {...reactions};
    if (emoji.isEmpty) {
      next.remove(who);
    } else {
      next[who] = emoji;
    }
    return copyWith(reactions: next);
  }

  ChatMessage copyWith({
    String? id,
    String? contactId,
    bool? outgoing,
    int? ts,
    String? text,
    ChatState? state,
    String? reason,
    bool? read,
    String? fileId,
    String? fileName,
    int? fileSize,
    String? fileMime,
    String? fileSha256,
    String? fileStatus,
    String? filePath,
    String? fileKey,
    int? arrivedAt,
    bool? voiceNote,
    ChatReply? replyTo,
    Map<String, String>? reactions,
    int? editedAt,
    bool? deletedForAll,
    bool? forwarded,
    bool clearReplyTo = false,
  }) => ChatMessage(
    id: id ?? this.id,
    contactId: contactId ?? this.contactId,
    outgoing: outgoing ?? this.outgoing,
    ts: ts ?? this.ts,
    text: text ?? this.text,
    state: state ?? this.state,
    reason: reason ?? this.reason,
    read: read ?? this.read,
    fileId: fileId ?? this.fileId,
    fileName: fileName ?? this.fileName,
    fileSize: fileSize ?? this.fileSize,
    fileMime: fileMime ?? this.fileMime,
    fileSha256: fileSha256 ?? this.fileSha256,
    fileStatus: fileStatus ?? this.fileStatus,
    filePath: filePath ?? this.filePath,
    fileKey: fileKey ?? this.fileKey,
    arrivedAt: arrivedAt ?? this.arrivedAt,
    voiceNote: voiceNote ?? this.voiceNote,
    replyTo: clearReplyTo ? null : (replyTo ?? this.replyTo),
    reactions: reactions ?? this.reactions,
    editedAt: editedAt ?? this.editedAt,
    deletedForAll: deletedForAll ?? this.deletedForAll,
    forwarded: forwarded ?? this.forwarded,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'out': outgoing,
    'ts': ts,
    'text': text,
    'state': state.name,
    'reason': reason,
    'read': read,
    if (fileId != null) 'fileId': fileId,
    if (fileName != null) 'fileName': fileName,
    if (fileSize != null) 'fileSize': fileSize,
    if (fileMime != null) 'fileMime': fileMime,
    if (fileSha256 != null) 'fileSha256': fileSha256,
    if (fileStatus != null) 'fileStatus': fileStatus,
    if (filePath != null) 'filePath': filePath,
    if (fileKey != null) 'fileKey': fileKey,
    if (arrivedAt != null) 'arrivedAt': arrivedAt,
    if (voiceNote) 'voiceNote': true,
    if (replyTo case final quote?)
      'replyTo': {'id': quote.id, 'text': quote.text},
    if (reactions.isNotEmpty) 'reactions': reactions,
    if (editedAt != null) 'editedAt': editedAt,
    if (deletedForAll) 'deletedForAll': true,
    if (forwarded) 'forwarded': true,
  };

  static ChatMessage fromJson(String contactId, Map<String, dynamic> json) {
    final state = ChatState.values.where((s) => s.name == json['state']);
    final id = json['id'];
    final outgoing = json['out'];
    final ts = json['ts'];
    final text = json['text'];
    final reason = json['reason'];
    final read = json['read'];
    final fileId = json['fileId'];
    final fileName = json['fileName'];
    final fileSize = json['fileSize'];
    final fileMime = json['fileMime'];
    final fileSha256 = json['fileSha256'];
    final fileStatus = json['fileStatus'];
    final filePath = json['filePath'];
    final fileKey = json['fileKey'];
    final arrivedAt = json['arrivedAt'];
    final voiceNote = json['voiceNote'];
    final replyTo = _replyFrom(json['replyTo']);
    final reactions = _reactionsFrom(json['reactions']);
    final editedAt = json['editedAt'];
    final deletedForAll = json['deletedForAll'];
    final forwarded = json['forwarded'];
    if (id is! String ||
        outgoing is! bool ||
        ts is! int ||
        text is! String ||
        state.isEmpty ||
        (reason != null && reason is! String) ||
        (read != null && read is! bool) ||
        (fileId != null && fileId is! String) ||
        (fileName != null && fileName is! String) ||
        (fileSize != null && fileSize is! int) ||
        (fileMime != null && fileMime is! String) ||
        (fileSha256 != null && fileSha256 is! String) ||
        (fileStatus != null && fileStatus is! String) ||
        (filePath != null && filePath is! String) ||
        (fileKey != null && fileKey is! String) ||
        (arrivedAt != null && arrivedAt is! int) ||
        (voiceNote != null && voiceNote is! bool) ||
        (json['replyTo'] != null && replyTo == null) ||
        reactions == null ||
        (editedAt != null && editedAt is! int) ||
        (deletedForAll != null && deletedForAll is! bool) ||
        (forwarded != null && forwarded is! bool)) {
      throw const ChatStoreException('unreadable');
    }
    return ChatMessage(
      id: id,
      contactId: contactId,
      outgoing: outgoing,
      ts: ts,
      text: text,
      state: state.first,
      reason: reason as String?,
      read: read is bool ? read : outgoing,
      fileId: fileId as String?,
      fileName: fileName as String?,
      fileSize: fileSize as int?,
      fileMime: fileMime as String?,
      fileSha256: fileSha256 as String?,
      fileStatus: fileStatus as String?,
      filePath: filePath as String?,
      fileKey: fileKey as String?,
      arrivedAt: arrivedAt as int?,
      voiceNote: voiceNote == true,
      replyTo: replyTo,
      reactions: reactions,
      editedAt: editedAt as int?,
      deletedForAll: deletedForAll == true,
      forwarded: forwarded == true,
    );
  }

  /// The quote stored as `replyTo`, or null when it is absent or not a quote.
  /// A present but malformed quote gives null too, and [fromJson] then refuses
  /// the record.
  static ChatReply? _replyFrom(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || text is! String) return null;
    return (id: id, text: text);
  }

  /// The reactions stored as `reactions`: absent means none. Null when the
  /// value is not a map of "me" or "peer" to an emoji.
  static Map<String, String>? _reactionsFrom(Object? raw) {
    if (raw == null) return const {};
    if (raw is! Map) return null;
    final reactions = <String, String>{};
    for (final entry in raw.entries) {
      final who = entry.key;
      final emoji = entry.value;
      if (who is! String || (who != 'me' && who != 'peer')) return null;
      if (emoji is! String) return null;
      reactions[who] = emoji;
    }
    return reactions;
  }
}

/// The stored chats cannot be read. They are never overwritten: the app
/// explains the problem instead.
class ChatStoreException implements Exception {
  const ChatStoreException(this.reason);

  final String reason;

  @override
  String toString() => 'ChatStoreException: $reason';
}

/// The history of each chat, kept in the encrypted vault.
/// Conversations are stored per contact under separate keys (`sotto.chats.contact.<id>`),
/// with a directory index under `sotto.chats.contacts.v1`. Each chat also has a
/// summary (`sotto.chats.summary.<id>`) with its last message and unread count,
/// so the chat list does not read whole histories.
/// Legacy monolithic stores (`sotto.chats.v1`) are automatically migrated.
class ChatStore {
  ChatStore(
    this._store, {
    this.files,
    this.browserMemoryBytes = defaultBrowserMemoryBytes,
    void Function(String event)? log,
  }) : _log = log ?? EventLog.instance.add;

  /// Where problems with a chat's records are reported (the diagnostic report).
  /// Never a contact, an id or any text of a message.
  final void Function(String event) _log;

  /// The problems reported so far, by contact, so that a chat which stays
  /// broken is reported once, not on every change.
  final _reported = <String>{};

  void _report(String contactId, String problem) {
    if (_reported.add('$contactId $problem')) _log(problem);
  }

  /// Where received files are kept, encrypted. Null in the browser, which
  /// keeps none.
  final ReceivedFileStore? files;

  /// How many bytes of files and voice notes the browser holds at most.
  static const defaultBrowserMemoryBytes = 150 * 1024 * 1024;

  /// The most bytes of files the browser holds in memory. Past it, the files
  /// used least recently are let go, and show as no longer on this device.
  final int browserMemoryBytes;

  /// Files and voice notes the browser holds for the life of the tab, least
  /// recently used first. Keys are `f:<file id>` for files and `v:<message
  /// id>` for voice notes. Never in the vault or in browser storage, so a
  /// reload loses them.
  final _browserHeld = <String, Uint8List>{};

  /// The bytes in [_browserHeld], in all.
  int _browserHeldBytes = 0;

  /// The bytes of files and voice notes the browser holds now.
  int get browserHeldBytes => _browserHeldBytes;

  static String _fileKey(String id) => 'f:$id';
  static String _voiceKey(String id) => 'v:$id';

  void _hold(String key, Uint8List bytes) {
    _drop(key);
    _browserHeld[key] = bytes;
    _browserHeldBytes += bytes.length;
    // The oldest go first; the one just added always stays.
    while (_browserHeldBytes > browserMemoryBytes && _browserHeld.length > 1) {
      final oldest = _browserHeld.keys.first;
      if (oldest == key) break;
      _drop(oldest);
    }
  }

  /// The bytes held under [key], now the most recently used.
  Uint8List? _held(String key) {
    final bytes = _browserHeld.remove(key);
    if (bytes != null) _browserHeld[key] = bytes;
    return bytes;
  }

  void _drop(String key) {
    final bytes = _browserHeld.remove(key);
    if (bytes != null) _browserHeldBytes -= bytes.length;
  }

  /// Legacy storage key for monolithic chat storage.
  static const storageKey = 'sotto.chats.v1';

  /// Key for the list of contact IDs with stored messages.
  static const contactsIndexKey = 'sotto.chats.contacts.v1';

  /// Storage key for a specific contact's messages.
  static String contactKey(String contactId) =>
      'sotto.chats.contact.$contactId';

  /// Storage key for a contact's pending reactions, edits and deletes (see
  /// [queueControl]).
  static String pendingKey(String contactId) =>
      'sotto.chats.pending.$contactId';

  /// Storage key for a chat's summary: its last message as stored and its
  /// unread count. Written with every change to the chat's messages.
  static String summaryKey(String contactId) =>
      'sotto.chats.summary.$contactId';

  /// Most pending controls kept for one contact. Past this, the oldest is
  /// dropped, so a chat that stays offline for long cannot grow without limit.
  static const maxPendingControls = 100;

  final SecretStore _store;
  final _changes = StreamController<void>.broadcast();

  /// Emits whenever messages are added, updated, read, or deleted.
  Stream<void> get changes => _changes.stream;

  /// Cached contact index.
  Set<String>? _contactIndex;

  /// In-memory cache of contact ID -> messages.
  final _cachedChats = <String, List<ChatMessage>>{};

  bool _migrated = false;

  /// The last write asked for. Writes run one after another, in the order
  /// they were asked for, so a change asked for after a message is stored
  /// always lands after it (for example, marking it not sent).
  Future<void> _tail = Future<void>.value();

  Future<T> _inOrder<T>(Future<T> Function() write) {
    final result = _tail.then((_) => write());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _checkMigration() async {
    if (_migrated) return;
    final legacy = await _store.read(storageKey);
    if (legacy != null) {
      final Object? json;
      try {
        json = jsonDecode(legacy);
      } on FormatException {
        throw const ChatStoreException('unreadable');
      }
      if (json is! Map<String, dynamic>) {
        throw const ChatStoreException('unreadable');
      }
      final index = <String>{};
      for (final entry in json.entries) {
        final list = entry.value;
        if (list is! List) throw const ChatStoreException('unreadable');
        final messages = <ChatMessage>[];
        for (final item in list) {
          if (item is! Map<String, dynamic>) {
            throw const ChatStoreException('unreadable');
          }
          messages.add(ChatMessage.fromJson(entry.key, item));
        }
        if (messages.isNotEmpty) {
          index.add(entry.key);
          _cachedChats[entry.key] = messages;
          await _store.write(
            contactKey(entry.key),
            jsonEncode([for (final m in messages) m.toJson()]),
          );
        }
      }
      _contactIndex = index;
      await _store.write(contactsIndexKey, jsonEncode(index.toList()));
      await _store.delete(storageKey);
    }
    _migrated = true;
  }

  Future<Set<String>> _loadIndex() async {
    if (_contactIndex case final index?) return index;
    await _checkMigration();
    final raw = await _store.read(contactsIndexKey);
    if (raw == null) {
      return _contactIndex = <String>{};
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final index = <String>{};
    for (final item in json) {
      if (item is String) index.add(item);
    }
    return _contactIndex = index;
  }

  Future<List<ChatMessage>> _loadContact(String contactId) async {
    if (_cachedChats[contactId] case final cached?) {
      return cached;
    }
    await _checkMigration();
    final raw = await _store.read(contactKey(contactId));
    if (raw == null) {
      return _cachedChats[contactId] = [];
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final messages = <ChatMessage>[];
    for (final item in json) {
      if (item is! Map<String, dynamic>) {
        throw const ChatStoreException('unreadable');
      }
      messages.add(ChatMessage.fromJson(contactId, item));
    }
    return _cachedChats[contactId] = messages;
  }

  /// Saves [list] as the chat with [contactId], with its summary and the
  /// contact index, in one write, so they are stored together or not at all.
  /// The cache takes the new list only once it is stored, so a failed write
  /// leaves what is on screen equal to what is saved. Callers pass a copy of
  /// the cached list.
  Future<void> _saveContact(String contactId, List<ChatMessage> list) async {
    final index = await _loadIndex();
    final next = {...index};
    if (list.isNotEmpty) {
      next.add(contactId);
    } else {
      next.remove(contactId);
    }
    final indexChanged = next.length != index.length;
    await _store.writeAll(
      {
        contactKey(contactId): jsonEncode([for (final m in list) m.toJson()]),
        if (list.isNotEmpty) summaryKey(contactId): _summaryJson(list),
        if (indexChanged) contactsIndexKey: jsonEncode(next.toList()),
      },
      deleted: [if (list.isEmpty) summaryKey(contactId)],
    );
    _cachedChats[contactId] = list;
    if (indexChanged) _contactIndex = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// The summary record of [list]: its last message as stored and its unread
  /// count.
  static String _summaryJson(List<ChatMessage> list) =>
      jsonEncode({'last': list.last.toJson(), 'unread': _unreadIn(list)});

  /// The number of incoming messages in [list] not yet read.
  static int _unreadIn(Iterable<ChatMessage> list) =>
      list.where((m) => !m.outgoing && !m.read).length;

  /// The messages with [contactId], oldest first.
  /// When [limit] is provided, returns at most [limit] messages ending at [offset]
  /// messages before the newest message.
  Future<List<ChatMessage>> messages(
    String contactId, {
    int? limit,
    int? offset,
  }) async {
    final all = await _loadContact(contactId);
    if (limit == null || limit <= 0) {
      return List.unmodifiable(all);
    }
    final skipFromEnd = offset ?? 0;
    final endIndex = all.length - skipFromEnd;
    if (endIndex <= 0) return const [];
    final startIndex = endIndex > limit ? endIndex - limit : 0;
    return List.unmodifiable(all.sublist(startIndex, endIndex));
  }

  /// The total number of stored messages for [contactId].
  Future<int> messageCount(String contactId) async =>
      (await _loadContact(contactId)).length;

  /// The chats that have messages, by contact ID.
  Future<List<String>> contactIds() async => (await _loadIndex()).toList();

  Future<ChatMessage?> find(String contactId, String id) async {
    for (final message in await _loadContact(contactId)) {
      if (message.id == id) return message;
    }
    return null;
  }

  Future<bool> contains(String contactId, String id) async =>
      (await find(contactId, id)) != null;

  /// Stores [message] and returns it as stored. A message already stored (same
  /// id) is not added twice; the stored one is returned.
  ///
  /// A quote of a message in the same chat takes that message's text as it is
  /// stored when this write runs (see [_withQuoteOf]). The read and the write
  /// are one step, as in [changeMessage], so a reply written while its message
  /// is edited or deleted never keeps the text the message had before.
  Future<ChatMessage> add(ChatMessage message) => _inOrder(() async {
    final list = [...await _loadContact(message.contactId)];
    final index = list.indexWhere((m) => m.id == message.id);
    if (index >= 0) return list[index];
    final stored = _withQuoteOf(list, message);
    list.add(stored);
    await _saveContact(message.contactId, list);
    return stored;
  });

  /// [message] with its quote given the text of the message it quotes in
  /// [list], as that message is stored now: empty once it is deleted for
  /// everyone. A quote of a message that is not in [list] keeps the text it
  /// came with.
  static ChatMessage _withQuoteOf(List<ChatMessage> list, ChatMessage message) {
    final quote = message.replyTo;
    if (quote == null) return message;
    final index = list.indexWhere((m) => m.id == quote.id);
    if (index < 0) return message;
    final target = list[index];
    final text = target.deletedForAll ? '' : ChatFrames.quoteText(target.text);
    return message.copyWith(replyTo: (id: quote.id, text: text));
  }

  /// Updates an existing message in-place.
  Future<void> updateMessage(ChatMessage message) => _inOrder(() async {
    final list = [...await _loadContact(message.contactId)];
    final index = list.indexWhere((m) => m.id == message.id);
    if (index < 0) return;
    list[index] = message;
    await _saveContact(message.contactId, list);
  });

  Future<void> setState(
    String contactId,
    String id,
    ChatState state, {
    String? reason,
  }) => _inOrder(() async {
    final list = [...await _loadContact(contactId)];
    final index = list.indexWhere((m) => m.id == id);
    if (index < 0) return;
    list[index] = list[index].withState(state, reason: reason);
    await _saveContact(contactId, list);
  });

  /// Changes the message [id] in the chat with [contactId]. [change] gets the
  /// stored message and returns its replacement, or null to leave it as it is.
  /// The read and the write happen in one step, so a change made meanwhile is
  /// never lost. Returns whether the message was changed.
  ///
  /// A message that comes out deleted for everyone also takes its text out of
  /// the chat's quotes. A message whose text is edited gives its quotes the new
  /// text (see [_setQuotes]), so no quote keeps the text it had before.
  Future<bool> changeMessage(
    String contactId,
    String id,
    ChatMessage? Function(ChatMessage current) change,
  ) => _inOrder(() async {
    final list = [...await _loadContact(contactId)];
    final index = list.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    final before = list[index];
    final next = change(before);
    if (next == null) return false;
    list[index] = next;
    if (next.deletedForAll) {
      // The deleted message keeps no quote of its own.
      list[index] = next.copyWith(clearReplyTo: true);
      _setQuotes(list, id, '');
    } else if (next.text != before.text) {
      _setQuotes(list, id, ChatFrames.quoteText(next.text));
    }
    await _saveContact(contactId, list);
    return true;
  });

  /// Gives each quote of the message [id] in [list] the text [quote]: empty
  /// once the message is deleted for everyone, its new text once it is edited.
  /// The quote keeps its id either way.
  static void _setQuotes(List<ChatMessage> list, String id, String quote) {
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.replyTo?.id == id) {
        list[i] = m.copyWith(replyTo: (id: id, text: quote));
      }
    }
  }

  /// The pending reactions, edits and deletes for the contact, oldest first.
  Future<List<ControlFrame>> pendingControls(String contactId) =>
      _inOrder(() => _loadPending(contactId));

  /// Keeps [control] until the chat with [contactId] can carry it (see
  /// `docs/PROTOCOL.md` §5.10). A control replaces the older one of its kind
  /// on the same message: a reaction replaces a reaction, an edit replaces an
  /// edit, and a delete replaces both. So a message can have one pending
  /// reaction and one pending edit at once, never two of the same kind. Past
  /// [maxPendingControls], the oldest is dropped.
  Future<void> queueControl(String contactId, ControlFrame control) =>
      _inOrder(() async {
        final list = [...await _loadPending(contactId)];
        list.removeWhere((older) => _supersedes(control, older));
        list.add(control);
        while (list.length > maxPendingControls) {
          list.removeAt(0);
        }
        await _savePending(contactId, list);
      });

  /// Takes [control] off the pending list, once it has been sent. Only the
  /// same control is removed, so one queued meanwhile is kept.
  Future<void> removeControl(String contactId, ControlFrame control) =>
      _inOrder(() async {
        final sent = ChatFrames.encode(control);
        final list = [...await _loadPending(contactId)];
        final before = list.length;
        list.removeWhere((c) => ChatFrames.encode(c) == sent);
        if (list.length != before) await _savePending(contactId, list);
      });

  /// Whether [newer] replaces [older] in the pending list.
  static bool _supersedes(ControlFrame newer, ControlFrame older) {
    if (newer.id != older.id) return false;
    return switch (newer) {
      DeleteFrame() => true,
      ReactFrame() => older is ReactFrame,
      EditFrame() => older is EditFrame,
    };
  }

  Future<List<ControlFrame>> _loadPending(String contactId) async {
    await _checkMigration();
    final raw = await _store.read(pendingKey(contactId));
    if (raw == null) return [];
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final controls = <ControlFrame>[];
    for (final item in json) {
      if (item is! String) throw const ChatStoreException('unreadable');
      try {
        final frame = ChatFrames.decode(item);
        if (frame is! ControlFrame) throw const ChatFrameException('unknown');
        controls.add(frame);
      } on ChatFrameException {
        throw const ChatStoreException('unreadable');
      }
    }
    return controls;
  }

  Future<void> _savePending(String contactId, List<ControlFrame> list) async {
    if (list.isEmpty) {
      await _store.delete(pendingKey(contactId));
      return;
    }
    await _store.write(
      pendingKey(contactId),
      jsonEncode([for (final c in list) ChatFrames.encode(c)]),
    );
  }

  /// Deletes the whole chat with [contactId].
  Future<void> deleteChat(String contactId) async {
    final removed = await _inOrder(() async {
      await _checkMigration();
      final messages = [...await _loadContact(contactId)];
      final index = await _loadIndex();
      final next = {...index}..remove(contactId);
      final indexChanged = next.length != index.length;
      await _store.writeAll(
        {if (indexChanged) contactsIndexKey: jsonEncode(next.toList())},
        deleted: [
          summaryKey(contactId),
          pendingKey(contactId),
          contactKey(contactId),
        ],
      );
      _cachedChats.remove(contactId);
      if (indexChanged) _contactIndex = next;
      if (!_changes.isClosed) {
        _changes.add(null);
      }
      return messages;
    });
    await _discardFiles(removed);
  }

  /// Deletes the files that [messages] received. Done after the chat records
  /// are gone, so a file is never left behind by a message that is no longer
  /// stored.
  Future<void> _discardFiles(Iterable<ChatMessage> messages) async {
    for (final message in messages) {
      await files?.remove(message.filePath);
      _drop(_voiceKey(message.id));
      _drop(_fileKey(message.fileId ?? message.id));
      _drop(_fileKey(message.id));
    }
  }

  /// The decrypted bytes of a received file. Throws [ReceivedFileException]
  /// when the file is not on this device or cannot be opened.
  Future<Uint8List> readFile(ChatMessage message) async {
    final store = files;
    final name = message.filePath;
    final key = message.fileKey;
    final fileId = message.fileId ?? message.id;
    if (store == null || name == null || key == null) {
      final held =
          _held(_fileKey(fileId)) ??
          _held(_fileKey(message.id)) ??
          _held(_voiceKey(message.id));
      if (held != null) return held;
      throw const ReceivedFileException('missing');
    }
    return store.read(name: name, key: key);
  }

  /// Whether the bytes of a file are still here: in the file
  /// store, or held by the browser for this tab.
  bool hasFile(ChatMessage message) {
    final fileId = message.fileId ?? message.id;
    return _browserHeld.containsKey(_fileKey(fileId)) ||
        _browserHeld.containsKey(_fileKey(message.id)) ||
        _browserHeld.containsKey(_voiceKey(message.id)) ||
        (files != null && message.filePath != null && message.fileKey != null);
  }

  /// Whether the bytes of a voice note are still here to play: in the file
  /// store, or held by the browser for this tab.
  bool hasVoice(ChatMessage message) =>
      _browserHeld.containsKey(_voiceKey(message.id)) ||
      (files != null && message.filePath != null && message.fileKey != null);

  /// Keeps the bytes of a voice note the sender offered, so its own bubble
  /// can play it. Native: an encrypted file, like a received one. Browser:
  /// memory for this tab. Returns the message with its file recorded.
  Future<ChatMessage> keepVoice(ChatMessage message, Uint8List bytes) async {
    final store = files;
    if (store == null) {
      rememberVoice(message.id, bytes);
      return message;
    }
    try {
      final kept = await store.save(bytes);
      final updated = message.copyWith(filePath: kept.name, fileKey: kept.key);
      await updateMessage(updated);
      return updated;
    } catch (_) {
      // The offer still goes; only the sender's own playback is lost.
      return message;
    }
  }

  /// Keeps a voice note the browser received, for this tab (see [readFile]).
  void rememberVoice(String id, Uint8List bytes) {
    _hold(_voiceKey(id), bytes);
  }

  /// Drops a voice note the browser held, when its message is gone.
  void forgetVoice(String id) {
    _drop(_voiceKey(id));
  }

  /// Keeps a file attachment the browser sent or received, for this tab.
  /// Within [browserMemoryBytes]: older files may be let go.
  void rememberFile(String id, Uint8List bytes) {
    _hold(_fileKey(id), bytes);
  }

  /// Drops a file attachment the browser held, when its message is gone.
  void forgetFile(String id) {
    _drop(_fileKey(id));
  }

  /// Keeps the bytes of a file this device sends, so it can be sent when the
  /// contact accepts it (and shown here). Native: an encrypted file. Browser:
  /// memory for this tab (a voice note as one, any other file as a file),
  /// with a `web:` path. Returns [message] with where the file is kept; the
  /// message itself is not stored here.
  Future<ChatMessage> keepOutgoingFile(
    ChatMessage message,
    Uint8List bytes,
  ) async {
    final store = files;
    final id = message.fileId ?? message.id;
    if (store == null) {
      if (message.voiceNote) {
        rememberVoice(message.id, bytes);
      } else {
        rememberFile(id, bytes);
      }
      return message.copyWith(filePath: 'web:$id');
    }
    final kept = await store.save(bytes);
    return message.copyWith(filePath: kept.name, fileKey: kept.key);
  }

  /// A decrypted copy of a received file, for another app to open. The copy
  /// is plaintext in the temporary folder until the app next starts.
  Future<File> openCopy(ChatMessage message) async {
    final store = files;
    if (store == null) throw const ReceivedFileException('missing');
    final bytes = await readFile(message);
    return store.writeOpenCopy(message.fileName ?? 'file', bytes);
  }

  /// Moves received files that earlier versions kept as plaintext into the
  /// encrypted store. A file that cannot be moved is left as it is and opens
  /// as unavailable.
  Future<void> encryptLegacyFiles() async {
    final store = files;
    if (store == null) return;
    for (final contactId in await contactIds()) {
      final list = await _tryLoad(contactId) ?? const <ChatMessage>[];
      for (final message in list) {
        final path = message.filePath;
        if (path == null ||
            message.fileKey != null ||
            path.startsWith('web:')) {
          continue;
        }
        try {
          final sealed = await store.save(await File(path).readAsBytes());
          await updateMessage(
            message.copyWith(filePath: sealed.name, fileKey: sealed.key),
          );
          await store.remove(path);
        } catch (_) {}
      }
    }
  }

  /// Drops a chat that has no messages left.
  Future<void> _forgetEmptyChat(String contactId) async {
    final index = await _loadIndex();
    final next = {...index}..remove(contactId);
    final indexChanged = next.length != index.length;
    await _store.writeAll(
      {if (indexChanged) contactsIndexKey: jsonEncode(next.toList())},
      deleted: [summaryKey(contactId), contactKey(contactId)],
    );
    _cachedChats[contactId] = [];
    if (indexChanged) _contactIndex = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// Deletes a single message with [id] in the chat with [contactId].
  Future<void> deleteMessage(String contactId, String id) async {
    final removed = await _inOrder(() async {
      final list = [...await _loadContact(contactId)];
      final index = list.indexWhere((m) => m.id == id);
      if (index < 0) return null;
      final message = list.removeAt(index);
      if (list.isEmpty) {
        await _forgetEmptyChat(contactId);
      } else {
        await _saveContact(contactId, list);
      }
      return message;
    });
    if (removed != null) await _discardFiles([removed]);
  }

  static const retentionPrefix = 'sotto.chats.retention.';

  /// Marks all incoming messages from [contactId] as read. Returns the ids
  /// of messages that were newly marked as read.
  Future<List<String>> markAsRead(String contactId) => _inOrder(() async {
    final list = [...await _loadContact(contactId)];
    final readIds = <String>[];
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final message = list[i];
      if (!message.outgoing && !message.read) {
        list[i] = message.copyWith(read: true);
        readIds.add(message.id);
        changed = true;
      }
    }
    if (changed) {
      await _saveContact(contactId, list);
    }
    return readIds;
  });

  /// The disappearing message duration for [contactId]. Duration.zero means off.
  Future<Duration> retention(String contactId) async {
    final raw = await _store.read('$retentionPrefix$contactId');
    if (raw == null) return Duration.zero;
    final seconds = int.tryParse(raw);
    return seconds == null || seconds <= 0
        ? Duration.zero
        : Duration(seconds: seconds);
  }

  /// Sets the disappearing message duration for [contactId]. Duration.zero turns it off.
  Future<void> setRetention(
    String contactId,
    Duration duration, {
    DateTime Function()? clock,
  }) => _inOrder(() async {
    if (duration <= Duration.zero) {
      await _store.delete('$retentionPrefix$contactId');
    } else {
      await _store.write('$retentionPrefix$contactId', '${duration.inSeconds}');
    }
    final result = await _sweepInternal(contactId: contactId, clock: clock);
    // The files go once the records are gone (see _discardFiles).
    return result.removed;
  }).then((removed) => _discardFiles(removed));

  /// Sweeps expired messages across all chats (or only [contactId]).
  /// Returns the number of purged messages.
  Future<int> sweepExpired({
    String? contactId,
    DateTime Function()? clock,
  }) async {
    final result = await _inOrder(
      () => _sweepInternal(contactId: contactId, clock: clock),
    );
    await _discardFiles(result.removed);
    return result.count;
  }

  /// Removes the messages that have expired, and returns how many there were
  /// and which ones (their files are deleted by the caller).
  Future<({int count, List<ChatMessage> removed})> _sweepInternal({
    String? contactId,
    DateTime Function()? clock,
  }) async {
    final nowMs = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    final targetIds = contactId != null
        ? [contactId]
        : (await _loadIndex()).toList();
    final removed = <ChatMessage>[];
    for (final id in targetIds) {
      final dur = await retention(id);
      if (dur <= Duration.zero) continue;
      final maxAgeMs = dur.inMilliseconds;
      final List<ChatMessage> list;
      try {
        list = [...await _loadContact(id)];
      } on ChatStoreException {
        continue;
      }
      final expired = list
          .where((m) => (nowMs - m.clockMs) > maxAgeMs)
          .toList();
      if (expired.isEmpty) continue;
      removed.addAll(expired);
      list.removeWhere((m) => (nowMs - m.clockMs) > maxAgeMs);
      if (list.isEmpty) {
        await _forgetEmptyChat(id);
      } else {
        await _saveContact(id, list);
      }
    }
    return (count: removed.length, removed: removed);
  }

  /// The messages of [contactId], or null when that chat cannot be read. Lists
  /// over all chats skip such a chat, so one unreadable chat does not stop the
  /// Chats tab or the unread badge (the chat itself still reports the problem).
  Future<List<ChatMessage>?> _tryLoad(String contactId) async {
    try {
      return await _loadContact(contactId);
    } on ChatStoreException {
      return null;
    }
  }

  /// The summary of the chat with [contactId]: its last message as stored and
  /// its unread count. Null when the chat has no messages.
  ///
  /// A chat with no summary record (one from an earlier vault) is rebuilt from
  /// its messages once, and the record is written. A record that cannot be
  /// read throws [ChatStoreException], and is not overwritten here.
  Future<ChatThreadSummary?> threadSummary(String contactId) async {
    final raw = await _store.read(summaryKey(contactId));
    if (raw != null) return _readSummary(contactId, raw);
    return _inOrder<ChatThreadSummary?>(() async {
      // A change that ran first may have written the record meanwhile.
      final again = await _store.read(summaryKey(contactId));
      if (again != null) return _readSummary(contactId, again);
      final list = await _loadContact(contactId);
      if (list.isEmpty) return null;
      try {
        await _store.write(summaryKey(contactId), _summaryJson(list));
      } catch (_) {
        // The chat is listed from its messages all the same, and the record
        // is written again the next time it is read.
        _report(contactId, 'chat summary cannot be saved');
      }
      return ChatThreadSummary(
        contactId: contactId,
        lastMessage: list.last,
        unreadCount: _unreadIn(list),
      );
    });
  }

  /// The summary held in [raw] for [contactId]. Throws [ChatStoreException]
  /// when [raw] is not a summary, and reports it, since nothing else shows it:
  /// the chat's messages still read fine.
  ChatThreadSummary _readSummary(String contactId, String raw) {
    try {
      return _summaryFrom(contactId, raw);
    } on ChatStoreException {
      _report(contactId, 'chat summary cannot be read');
      rethrow;
    }
  }

  /// The summary held in [raw] for [contactId]. Throws [ChatStoreException]
  /// when [raw] is not a summary.
  static ChatThreadSummary _summaryFrom(String contactId, String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! Map<String, dynamic>) {
      throw const ChatStoreException('unreadable');
    }
    final last = json['last'];
    final unread = json['unread'];
    if (last is! Map<String, dynamic> || unread is! int || unread < 0) {
      throw const ChatStoreException('unreadable');
    }
    return ChatThreadSummary(
      contactId: contactId,
      lastMessage: ChatMessage.fromJson(contactId, last),
      unreadCount: unread,
    );
  }

  /// [threadSummary], or null when the chat's record cannot be read. Lists over
  /// all chats skip such a chat, as [_tryLoad] does.
  Future<ChatThreadSummary?> _tryLoadSummary(String contactId) async {
    try {
      return await threadSummary(contactId);
    } on ChatStoreException {
      return null;
    }
  }

  /// The number of unread incoming messages across all chats. Reads the
  /// summary records, not the messages.
  Future<int> totalUnreadCount() async {
    final ids = await _loadIndex();
    var count = 0;
    for (final id in ids) {
      count += (await _tryLoadSummary(id))?.unreadCount ?? 0;
    }
    return count;
  }

  /// The number of unread incoming messages with [contactId]. Reads the
  /// summary record, not the messages: the contacts list asks for it on every
  /// change.
  Future<int> unreadCount(String contactId) async =>
      (await _tryLoadSummary(contactId))?.unreadCount ?? 0;

  /// Returns conversation threads that have messages, newest first. Reads the
  /// summary records, not the messages.
  Future<List<ChatThreadSummary>> recentChats() async {
    final ids = await _loadIndex();
    final summaries = <ChatThreadSummary>[];
    for (final id in ids) {
      if (await _tryLoadSummary(id) case final summary?) {
        summaries.add(summary);
      }
    }
    summaries.sort(
      (a, b) => b.lastMessage.clockMs.compareTo(a.lastMessage.clockMs),
    );
    return summaries;
  }

  /// Searches all stored messages across all contacts matching [query].
  Future<List<ChatMessage>> searchAll(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final ids = await _loadIndex();
    final results = <ChatMessage>[];
    for (final id in ids) {
      final list = await _tryLoad(id);
      if (list == null) continue;
      for (final msg in list) {
        if (msg.text.toLowerCase().contains(q) ||
            (msg.fileName?.toLowerCase().contains(q) ?? false)) {
          results.add(msg);
        }
      }
    }
    results.sort((a, b) => b.clockMs.compareTo(a.clockMs));
    return results;
  }
}

/// A brief overview of a chat conversation for recent chat listings.
class ChatThreadSummary {
  const ChatThreadSummary({
    required this.contactId,
    required this.lastMessage,
    required this.unreadCount,
  });

  final String contactId;
  final ChatMessage lastMessage;
  final int unreadCount;
}
