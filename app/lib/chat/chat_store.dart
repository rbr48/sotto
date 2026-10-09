import 'dart:async';
import 'dart:convert';

import '../crypto/identity_store.dart';
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
    this.arrivedAt,
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
  final String? filePath;

  /// When an incoming message arrived on this device, in milliseconds since
  /// the epoch. Disappearing messages expire from this time, so a sender's
  /// clock cannot keep a message or purge it on arrival. Null for outgoing
  /// messages (their [ts] is this device's clock).
  final int? arrivedAt;

  bool get isAttachment => fileName != null;

  /// When this message expires from this device, judged by [ts] for outgoing
  /// messages and by [arrivedAt] for incoming ones.
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
    arrivedAt: arrivedAt,
  );

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
    int? arrivedAt,
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
    arrivedAt: arrivedAt ?? this.arrivedAt,
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
    if (arrivedAt != null) 'arrivedAt': arrivedAt,
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
    final arrivedAt = json['arrivedAt'];
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
        (arrivedAt != null && arrivedAt is! int)) {
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
      arrivedAt: arrivedAt as int?,
    );
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
/// with a directory index under `sotto.chats.contacts.v1`.
/// Legacy monolithic stores (`sotto.chats.v1`) are automatically migrated.
class ChatStore {
  ChatStore(this._store);

  /// Legacy storage key for monolithic chat storage.
  static const storageKey = 'sotto.chats.v1';

  /// Key for the list of contact IDs with stored messages.
  static const contactsIndexKey = 'sotto.chats.contacts.v1';

  /// Storage key for a specific contact's messages.
  static String contactKey(String contactId) =>
      'sotto.chats.contact.$contactId';

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

  /// Saves [list] as the chat with [contactId]. The cache takes the new list
  /// only once it is stored, so a failed write leaves what is on screen equal
  /// to what is saved. Callers pass a copy of the cached list.
  Future<void> _saveContact(String contactId, List<ChatMessage> list) async {
    await _store.write(
      contactKey(contactId),
      jsonEncode([for (final m in list) m.toJson()]),
    );
    _cachedChats[contactId] = list;
    final index = await _loadIndex();
    var indexChanged = false;
    if (list.isNotEmpty && index.add(contactId)) {
      indexChanged = true;
    } else if (list.isEmpty && index.remove(contactId)) {
      indexChanged = true;
    }
    if (indexChanged) {
      await _store.write(contactsIndexKey, jsonEncode(index.toList()));
    }
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

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

  /// Stores [message]. A message already stored (same id) is not added twice.
  Future<void> add(ChatMessage message) => _inOrder(() async {
    final list = [...await _loadContact(message.contactId)];
    if (list.any((m) => m.id == message.id)) return;
    list.add(message);
    await _saveContact(message.contactId, list);
  });

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

  /// Deletes the whole chat with [contactId].
  Future<void> deleteChat(String contactId) async {
    final removed = await _inOrder(() async {
      await _checkMigration();
      final messages = [...await _loadContact(contactId)];
      _cachedChats.remove(contactId);
      await _store.delete(contactKey(contactId));
      final index = await _loadIndex();
      if (index.remove(contactId)) {
        await _store.write(contactsIndexKey, jsonEncode(index.toList()));
      }
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
      await ChatFileStorage.deleteFile(message.filePath);
    }
  }

  /// Drops a chat that has no messages left.
  Future<void> _forgetEmptyChat(String contactId) async {
    await _store.delete(contactKey(contactId));
    final index = await _loadIndex();
    if (index.remove(contactId)) {
      await _store.write(contactsIndexKey, jsonEncode(index.toList()));
    }
    _cachedChats[contactId] = [];
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
  Future<int> sweepExpired({String? contactId, DateTime Function()? clock}) async {
    final result = await _inOrder(() => _sweepInternal(contactId: contactId, clock: clock));
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
      final expired = list.where((m) => (nowMs - m.clockMs) > maxAgeMs).toList();
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

  /// The number of unread incoming messages across all chats.
  Future<int> totalUnreadCount() async {
    final ids = await _loadIndex();
    var count = 0;
    for (final id in ids) {
      final list = await _tryLoad(id);
      if (list == null) continue;
      for (final message in list) {
        if (!message.outgoing && !message.read) count++;
      }
    }
    return count;
  }

  /// The number of unread incoming messages with [contactId].
  Future<int> unreadCount(String contactId) async {
    final list = [...await _loadContact(contactId)];
    var count = 0;
    for (final message in list) {
      if (!message.outgoing && !message.read) count++;
    }
    return count;
  }

  /// Returns conversation threads that have messages, newest first.
  Future<List<ChatThreadSummary>> recentChats() async {
    final ids = await _loadIndex();
    final summaries = <ChatThreadSummary>[];
    for (final id in ids) {
      final list = await _tryLoad(id);
      if (list == null) continue;
      if (list.isEmpty) continue;
      final lastMsg = list.last;
      var unread = 0;
      for (final msg in list) {
        if (!msg.outgoing && !msg.read) unread++;
      }
      summaries.add(
        ChatThreadSummary(
          contactId: id,
          lastMessage: lastMsg,
          unreadCount: unread,
        ),
      );
    }
    summaries.sort((a, b) => b.lastMessage.ts.compareTo(a.lastMessage.ts));
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
    results.sort((a, b) => b.ts.compareTo(a.ts));
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
