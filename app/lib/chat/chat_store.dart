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

  ChatMessage withState(ChatState next) => ChatMessage(
    id: id,
    contactId: contactId,
    outgoing: outgoing,
    ts: ts,
    text: text,
    state: next,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'out': outgoing,
    'ts': ts,
    'text': text,
    'state': state.name,
  };

  static ChatMessage fromJson(String contactId, Map<String, dynamic> json) {
    final state = ChatState.values.where((s) => s.name == json['state']);
    final id = json['id'];
    final outgoing = json['out'];
    final ts = json['ts'];
    final text = json['text'];
    if (id is! String ||
        outgoing is! bool ||
        ts is! int ||
        text is! String ||
        state.isEmpty) {
      throw const ChatStoreException('unreadable');
    }
    return ChatMessage(
      id: id,
      contactId: contactId,
      outgoing: outgoing,
      ts: ts,
      text: text,
      state: state.first,
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

  Future<void> setState(String contactId, String id, ChatState state) =>
      _inOrder(() async {
        final chats = await _load();
        final list = chats[contactId];
        final index = list?.indexWhere((m) => m.id == id) ?? -1;
        if (list == null || index < 0) return;
        list[index] = list[index].withState(state);
        await _save(chats);
      });

  /// Deletes the whole chat with [contactId].
  Future<void> deleteChat(String contactId) => _inOrder(() async {
    final chats = await _load();
    if (chats.remove(contactId) != null) await _save(chats);
  });

  Future<void> _save(Map<String, List<ChatMessage>> chats) => _store.write(
    storageKey,
    jsonEncode({
      for (final entry in chats.entries)
        entry.key: [for (final m in entry.value) m.toJson()],
    }),
  );
}
