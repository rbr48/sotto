import 'dart:async';
import 'dart:convert';

import '../crypto/identity_store.dart';

/// Where a message is. Outgoing: [sending] until stored on the other device
/// ([delivered]), or [notSent] when the session ended first. Incoming:
/// [received].
enum ChatState { sending, delivered, notSent, received }

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
  }) => ChatMessage(
    id: id ?? this.id,
    contactId: contactId ?? this.contactId,
    outgoing: outgoing ?? this.outgoing,
    ts: ts ?? this.ts,
    text: text ?? this.text,
    state: state ?? this.state,
    reason: reason ?? this.reason,
    read: read ?? this.read,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'out': outgoing,
    'ts': ts,
    'text': text,
    'state': state.name,
    'reason': reason,
    'read': read,
  };

  static ChatMessage fromJson(String contactId, Map<String, dynamic> json) {
    final state = ChatState.values.where((s) => s.name == json['state']);
    final id = json['id'];
    final outgoing = json['out'];
    final ts = json['ts'];
    final text = json['text'];
    final reason = json['reason'];
    final read = json['read'];
    if (id is! String ||
        outgoing is! bool ||
        ts is! int ||
        text is! String ||
        state.isEmpty ||
        (reason != null && reason is! String) ||
        (read != null && read is! bool)) {
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

/// The history of each chat, kept in the encrypted vault under one key
/// (`docs/MESSAGING_PLAN.md`). Kept until the person deletes it.
class ChatStore {
  ChatStore(this._store);

  static const storageKey = 'sotto.chats.v1';

  final SecretStore _store;
  final _changes = StreamController<void>.broadcast();

  /// Emits whenever messages are added, updated, read, or deleted.
  Stream<void> get changes => _changes.stream;

  /// Loaded on first use. Contact ID → messages, oldest first.
  Map<String, List<ChatMessage>>? _chats;

  /// The last write asked for. Writes run one after another, in the order
  /// they were asked for, so a change asked for after a message is stored
  /// always lands after it (for example, marking it not sent).
  Future<void> _tail = Future<void>.value();

  Future<T> _inOrder<T>(Future<T> Function() write) {
    final result = _tail.then((_) => write());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, List<ChatMessage>>> _load() async {
    if (_chats case final chats?) return chats;
    final stored = await _store.read(storageKey);
    if (stored == null) return _chats = {};
    final Object? json;
    try {
      json = jsonDecode(stored);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! Map<String, dynamic>) {
      throw const ChatStoreException('unreadable');
    }
    final chats = <String, List<ChatMessage>>{};
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
      chats[entry.key] = messages;
    }
    return _chats = chats;
  }

  /// The messages with [contactId], oldest first.
  Future<List<ChatMessage>> messages(String contactId) async =>
      List.unmodifiable((await _load())[contactId] ?? const []);

  /// The chats that have messages, by contact ID.
  Future<List<String>> contactIds() async => [
    for (final entry in (await _load()).entries)
      if (entry.value.isNotEmpty) entry.key,
  ];

  Future<ChatMessage?> find(String contactId, String id) async {
    for (final message in await messages(contactId)) {
      if (message.id == id) return message;
    }
    return null;
  }

  Future<bool> contains(String contactId, String id) async =>
      (await find(contactId, id)) != null;

  /// Stores [message]. A message already stored (same id) is not added twice.
  Future<void> add(ChatMessage message) => _inOrder(() async {
    final chats = await _load();
    final list = chats.putIfAbsent(message.contactId, () => []);
    if (list.any((m) => m.id == message.id)) return;
    list.add(message);
    await _save(chats);
  });

  Future<void> setState(
    String contactId,
    String id,
    ChatState state, {
    String? reason,
  }) => _inOrder(() async {
    final chats = await _load();
    final list = chats[contactId];
    final index = list?.indexWhere((m) => m.id == id) ?? -1;
    if (list == null || index < 0) return;
    list[index] = list[index].withState(state, reason: reason);
    await _save(chats);
  });

  /// Deletes the whole chat with [contactId].
  Future<void> deleteChat(String contactId) => _inOrder(() async {
    final chats = await _load();
    if (chats.remove(contactId) != null) await _save(chats);
  });

  /// Deletes a single message with [id] in the chat with [contactId].
  Future<void> deleteMessage(String contactId, String id) => _inOrder(() async {
    final chats = await _load();
    final list = chats[contactId];
    if (list == null) return;
    final index = list.indexWhere((m) => m.id == id);
    if (index >= 0) {
      list.removeAt(index);
      await _save(chats);
    }
  });

  /// Marks all incoming messages from [contactId] as read.
  Future<void> markAsRead(String contactId) => _inOrder(() async {
    final chats = await _load();
    final list = chats[contactId];
    if (list == null) return;
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final message = list[i];
      if (!message.outgoing && !message.read) {
        list[i] = message.copyWith(read: true);
        changed = true;
      }
    }
    if (changed) {
      await _save(chats);
    }
  });

  /// The number of unread incoming messages across all chats.
  Future<int> totalUnreadCount() async {
    final chats = await _load();
    var count = 0;
    for (final list in chats.values) {
      for (final message in list) {
        if (!message.outgoing && !message.read) count++;
      }
    }
    return count;
  }

  /// The number of unread incoming messages with [contactId].
  Future<int> unreadCount(String contactId) async {
    final list = (await _load())[contactId];
    if (list == null) return 0;
    var count = 0;
    for (final message in list) {
      if (!message.outgoing && !message.read) count++;
    }
    return count;
  }

  Future<void> _save(Map<String, List<ChatMessage>> chats) async {
    await _store.write(
      storageKey,
      jsonEncode({
        for (final entry in chats.entries)
          entry.key: [for (final m in entry.value) m.toJson()],
      }),
    );
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
