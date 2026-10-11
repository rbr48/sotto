import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_groups.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity_store.dart';

/// A Sotto ID: 32 bytes of signing key, as base64url.
String _member(int n) => b64Encode(List<int>.filled(32, n));

/// A group id, or a message id: 16 bytes, as base64url.
String _id(int n) => b64Encode(List<int>.filled(16, n));

/// [message] as it is stored, read back.
ChatMessage _reload(String scope, ChatMessage message) => ChatMessage.fromJson(
  scope,
  jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
);

/// A group message from [author] in [group].
ChatMessage _groupMessage({
  required String group,
  required String author,
  int n = 1,
  bool outgoing = false,
  Map<String, String> reactions = const {},
  Map<String, ChatState> memberStates = const {},
}) => ChatMessage(
  id: _id(n),
  contactId: group,
  groupId: group,
  authorId: author,
  outgoing: outgoing,
  read: outgoing,
  ts: 1700000000000 + n,
  text: 'hello $n',
  state: outgoing ? ChatState.sending : ChatState.received,
  reactions: reactions,
  memberStates: memberStates,
);

/// The JSON of a group message in [group] from [author], as stored.
Map<String, dynamic> _groupJson(String group, String author) => {
  ..._legacyJson(1),
  'groupId': group,
  'authorId': author,
};

/// A time in milliseconds, as the fixtures count from.
const _ts = 1700000000000;

/// A group of [self] with [others], all accepted, made at [createdAt].
ChatGroup _groupOf({
  required String id,
  required String self,
  required List<String> others,
  String name = 'Trip',
  MemberState selfState = MemberState.accepted,
  int createdAt = _ts,
}) => ChatGroup(
  id: id,
  name: name,
  selfId: self,
  createdAt: createdAt,
  members: [
    GroupMember(id: self, state: selfState, invitedAt: createdAt),
    for (final other in others)
      GroupMember(id: other, state: MemberState.accepted, invitedAt: createdAt),
  ],
);

/// A [SecretStore] that counts the reads of each key, and records each
/// [writeAll] with its deletes.
class _CountingSecrets implements SecretStore {
  _CountingSecrets(this._inner);

  final MemorySecretStore _inner;
  final reads = <String>[];
  final batches = <({Map<String, String> values, Set<String> deleted})>[];

  @override
  Future<String?> read(String key) {
    reads.add(key);
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) => _inner.delete(key);

  @override
  Future<void> writeAll(
    Map<String, String> values, {
    Iterable<String> deleted = const [],
  }) {
    batches.add((values: {...values}, deleted: deleted.toSet()));
    return _inner.writeAll(values, deleted: deleted);
  }
}

/// Checks that the summary record of the group [groupId] holds the last
/// message and unread count of its messages as they stand now.
Future<void> _expectGroupSummaryInStep(
  MemorySecretStore secrets,
  String groupId,
) async {
  final list = await ChatStore(secrets).messages(groupId);
  final raw = await secrets.read(ChatStore.groupSummaryKey(groupId));
  if (list.isEmpty) {
    expect(raw, isNull, reason: 'a group with no messages has no summary');
    return;
  }
  expect(raw, isNotNull, reason: 'the summary of $groupId');
  final json = jsonDecode(raw!) as Map<String, dynamic>;
  expect(json['last'], list.last.toJson(), reason: 'last of $groupId');
  expect(
    json['unread'],
    list.where((m) => !m.outgoing && !m.read).length,
    reason: 'unread of $groupId',
  );
}

/// The JSON of a message as an earlier build stored it: no group fields.
Map<String, dynamic> _legacyJson(int n) => {
  'id': _id(n),
  'out': false,
  'ts': 1700000000000 + n,
  'text': 'old',
  'state': 'received',
  'reason': null,
  'read': false,
};

void main() {
  group('group fields on a message', () {
    final group = _id(90);
    final alice = _member(1);
    final bob = _member(2);

    test('a group message keeps its group, author, member states and member reactions across a reload', () {
      final message = _groupMessage(
        group: group,
        author: alice,
        outgoing: true,
        reactions: {alice: '👍', bob: '🎉'},
        memberStates: {bob: ChatState.delivered, alice: ChatState.sending},
      );
      final again = _reload(group, message);

      expect(again.groupId, group);
      expect(again.contactId, group);
      expect(again.authorId, alice);
      expect(again.reactions, {alice: '👍', bob: '🎉'});
      expect(again.memberStates, {
        bob: ChatState.delivered,
        alice: ChatState.sending,
      });
    });

    test('a record from before groups loads with no group, author or member states', () {
      final message = ChatMessage.fromJson('bob', _legacyJson(1));

      expect(message.groupId, isNull);
      expect(message.authorId, isNull);
      expect(message.memberStates, isEmpty);
      expect(message.toJson().containsKey('groupId'), isFalse);
      expect(message.toJson().containsKey('authorId'), isFalse);
      expect(message.toJson().containsKey('memberStates'), isFalse);
    });

    test('a one-to-one message keeps "me" and "peer" as its reactors, and refuses a member id', () {
      final message = ChatMessage.fromJson('bob', {
        ..._legacyJson(2),
        'reactions': {'me': '👍', 'peer': '🎉'},
      });
      expect(message.reactions, {'me': '👍', 'peer': '🎉'});

      expect(
        () => ChatMessage.fromJson('bob', {
          ..._legacyJson(3),
          'reactions': {alice: '👍'},
        }),
        throwsA(isA<ChatStoreException>()),
      );
    });

    test('a group message refuses "me" and "peer" as its reactors', () {
      for (final reactor in ['me', 'peer']) {
        expect(
          () => ChatMessage.fromJson(group, {
            ..._groupJson(group, alice),
            'reactions': {reactor: '👍'},
          }),
          throwsA(isA<ChatStoreException>()),
          reason: reactor,
        );
      }
    });

    test('a group message with no author, or a member state that is not known, is refused', () {
      final noAuthor = _groupJson(group, alice)..remove('authorId');
      expect(
        () => ChatMessage.fromJson(group, noAuthor),
        throwsA(isA<ChatStoreException>()),
      );
      expect(
        () => ChatMessage.fromJson(group, {
          ..._groupJson(group, alice),
          'memberStates': {bob: 'waiting'},
        }),
        throwsA(isA<ChatStoreException>()),
      );
    });

    test('a group message stored under another group is refused', () {
      expect(
        () => ChatMessage.fromJson(_id(91), _groupJson(group, alice)),
        throwsA(isA<ChatStoreException>()),
      );
      expect(
        () => ChatMessage.fromJson(bob, _groupJson(group, alice)),
        throwsA(isA<ChatStoreException>()),
      );
    });
  });
  group('group records', () {
    final group = _id(90);
    final alice = _member(1);
    final bob = _member(2);
    final carol = _member(3);

    test(
      'a group is saved, and loads with its members and their states',
      () async {
        final secrets = MemorySecretStore();
        final made = _groupOf(id: group, self: alice, others: [bob, carol]);
        await ChatStore(secrets).saveGroup(made);

        final loaded = await ChatStore(secrets).group(group);
        expect(loaded, isNotNull);
        expect(loaded!.id, group);
        expect(loaded.name, 'Trip');
        expect(loaded.selfId, alice);
        expect(loaded.createdAt, _ts);
        expect(loaded.memberIds, [alice, bob, carol]);
        expect(loaded.memberOf(bob)!.state, MemberState.accepted);
        expect(loaded.memberOf(bob)!.invitedAt, _ts);
        expect(loaded.left, isFalse);
      },
    );

    test('a group this device left is stored as left', () async {
      final secrets = MemorySecretStore();
      final left = ChatGroups.leave(
        _groupOf(id: group, self: alice, others: [bob, carol]),
        alice,
      );
      await ChatStore(secrets).saveGroup(left);

      final loaded = await ChatStore(secrets).group(group);
      expect(loaded!.left, isTrue);
      expect(loaded.memberOf(alice)!.state, MemberState.left);
    });

    test('groups are listed in the order they were saved, and saving one again replaces its record', () async {
      final secrets = MemorySecretStore();
      final store = ChatStore(secrets);
      final invited = ChatGroups.create(
        selfId: alice,
        name: 'Trip',
        invitees: [bob, carol],
        contacts: {bob, carol},
        ts: _ts,
        random: Random(1),
      );
      final other = _groupOf(id: _id(92), self: alice, others: [bob, carol]);
      await store.saveGroup(invited);
      await store.saveGroup(other);
      await store.saveGroup(ChatGroups.decline(invited, bob));

      final listed = await ChatStore(secrets).groups();
      expect([for (final g in listed) g.id], [invited.id, other.id]);
      expect(listed.first.memberOf(bob)!.state, MemberState.declined);
    });

    test(
      'a record whose left flag does not match its members is refused',
      () async {
        final secrets = MemorySecretStore();
        await ChatStore(secrets)
            .saveGroup(_groupOf(id: group, self: alice, others: [bob, carol]));
        final record = jsonDecode(
          (await secrets.read(ChatStore.groupKey(group)))!,
        ) as Map<String, dynamic>;
        await secrets.write(
          ChatStore.groupKey(group),
          jsonEncode({...record, 'left': true}),
        );

        expect(
          () => ChatStore(secrets).group(group),
          throwsA(isA<ChatStoreException>()),
        );
      },
    );

    test(
      'a record that cannot be read is left out of the list, and reported once',
      () async {
        final secrets = MemorySecretStore();
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: _id(91), self: alice, others: [bob, carol]),
        );
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        await secrets.write(ChatStore.groupKey(group), '{"id": 7}');

        // A new store reads the records, not the groups this one has cached.
        final logged = <String>[];
        final fresh = ChatStore(secrets, log: logged.add);
        expect([for (final g in await fresh.groups()) g.id], [_id(91)]);
        expect(await fresh.groups(), hasLength(1));
        expect(logged, hasLength(1));
        expect(() => fresh.group(group), throwsA(isA<ChatStoreException>()));
      },
    );

    test(
      'a group name that is empty or longer than 64 characters is refused',
      () async {
        final secrets = MemorySecretStore();
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        final record = jsonDecode(
          (await secrets.read(ChatStore.groupKey(group)))!,
        ) as Map<String, dynamic>;
        for (final name in ['', 'x' * 65]) {
          await secrets.write(
            ChatStore.groupKey(group),
            jsonEncode({...record, 'name': name}),
          );
          expect(
            () => ChatStore(secrets).group(group),
            throwsA(isA<ChatStoreException>()),
            reason: 'a name of ${name.length} characters',
          );
        }
      },
    );
  });

  group('messages of a group', () {
    final group = _id(90);
    final other = _id(91);
    final alice = _member(1);
    final bob = _member(2);
    final carol = _member(3);

    test(
      'a group message is stored under its group, and reloads with its fields',
      () async {
        final secrets = MemorySecretStore();
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        await store.add(
          _groupMessage(
            group: group,
            author: bob,
            reactions: {bob: '👍'},
            memberStates: const {},
          ),
        );
        await store.add(
          _groupMessage(
            group: group,
            author: alice,
            n: 2,
            outgoing: true,
            memberStates: {bob: ChatState.read},
          ),
        );

        final loaded = await ChatStore(secrets).messages(group);
        expect([for (final m in loaded) m.id], [_id(1), _id(2)]);
        expect(loaded.first.groupId, group);
        expect(loaded.first.authorId, bob);
        expect(loaded.first.reactions, {bob: '👍'});
        expect(loaded.last.memberStates, {bob: ChatState.read});
        expect(await secrets.read(ChatStore.contactKey(group)), isNull);
      },
    );

    test('a group message is refused while its group is not saved', () async {
      final store = ChatStore(MemorySecretStore());
      expect(
        () => store.add(_groupMessage(group: group, author: bob)),
        throwsA(isA<StateError>()),
      );
      expect(await store.messages(group), isEmpty);
    });

    test('a message is stored once per group, and the same id in another group or chat is kept', () async {
      final secrets = MemorySecretStore();
      final store = ChatStore(secrets);
      await store.saveGroup(
        _groupOf(id: group, self: alice, others: [bob, carol]),
      );
      await store.saveGroup(
        _groupOf(id: other, self: alice, others: [bob, carol]),
      );
      final message = _groupMessage(group: group, author: bob);

      await store.add(message);
      await store.add(message);
      await store.add(_groupMessage(group: other, author: bob));
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: bob,
          outgoing: false,
          ts: _ts + 1,
          text: 'one-to-one',
          state: ChatState.received,
        ),
      );

      expect(await store.messageCount(group), 1);
      expect(await store.messageCount(other), 1);
      expect(await store.messageCount(bob), 1);
    });
  });

  group('the chat list with groups', () {
    final group = _id(90);
    final other = _id(91);
    final alice = _member(1);
    final bob = _member(2);
    final carol = _member(3);

    test(
      'a group with messages is listed with its last message and unread count',
      () async {
        final secrets = MemorySecretStore();
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        await store.add(_groupMessage(group: group, author: bob));
        await store.add(
          _groupMessage(group: group, author: alice, n: 2, outgoing: true),
        );

        final chats = await ChatStore(secrets).recentChats();
        expect(chats, hasLength(1));
        final chat = chats.single;
        expect(chat.contactId, group);
        expect(chat.groupId, group);
        expect(chat.lastMessage!.id, _id(2));
        expect(chat.unreadCount, 1);
        expect(chat.sortMs, _ts + 2);
        await _expectGroupSummaryInStep(secrets, group);
      },
    );

    test('an empty group is listed at its creation time, with no last message, and orders with the chats', () async {
      final secrets = MemorySecretStore();
      final store = ChatStore(secrets);
      await store.saveGroup(
        _groupOf(
          id: group,
          self: alice,
          others: [bob, carol],
          createdAt: _ts + 50,
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(9),
          contactId: bob,
          outgoing: true,
          ts: _ts + 10,
          text: 'contact',
          state: ChatState.delivered,
        ),
      );

      var chats = await ChatStore(secrets).recentChats();
      expect([for (final c in chats) c.contactId], [group, bob]);
      final empty = chats.first;
      expect(empty.groupId, group);
      expect(empty.lastMessage, isNull);
      expect(empty.groupCreatedMs, _ts + 50);
      expect(empty.sortMs, _ts + 50);
      expect(empty.unreadCount, 0);
      expect(await secrets.read(ChatStore.groupSummaryKey(group)), isNull);

      await store.add(_groupMessage(group: group, author: bob, n: 2));
      chats = await ChatStore(secrets).recentChats();
      expect([for (final c in chats) c.contactId], [bob, group]);
      expect(chats.last.lastMessage!.id, _id(2));
    });

    test('a pinned group comes first, and an archived group leaves the main list for the archived one', () async {
      final secrets = MemorySecretStore();
      final store = ChatStore(secrets);
      await store.saveGroup(
        _groupOf(id: group, self: alice, others: [bob, carol]),
      );
      await store.saveGroup(
        _groupOf(id: other, self: alice, others: [bob, carol]),
      );
      await store.add(_groupMessage(group: group, author: bob, n: 1));
      await store.add(_groupMessage(group: other, author: bob, n: 5));

      expect(await store.setPinned(group, true, at: _ts), ChatPinResult.pinned);
      var chats = await ChatStore(secrets).recentChats();
      expect([for (final c in chats) c.contactId], [group, other]);
      expect(chats.first.meta.pinnedAt, _ts);

      await store.setArchived(other, true);
      chats = await ChatStore(secrets).recentChats();
      expect([for (final c in chats) c.contactId], [group]);
      final archived = await ChatStore(secrets).archivedChats();
      expect([for (final c in archived) c.contactId], [other]);
      await _expectGroupSummaryInStep(secrets, other);
    });

    test(
      'a group counts its unread incoming messages, and markAsRead reads them',
      () async {
        final secrets = MemorySecretStore();
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        await store.add(_groupMessage(group: group, author: bob));
        await store.add(_groupMessage(group: group, author: carol, n: 2));
        await store.add(
          _groupMessage(group: group, author: alice, n: 3, outgoing: true),
        );

        expect(await store.unreadCount(group), 2);
        expect(await store.totalUnreadCount(), 2);

        expect(await store.markAsRead(group), [_id(1), _id(2)]);
        expect(await store.unreadCount(group), 0);
        expect(await store.totalUnreadCount(), 0);
        expect(await store.markAsRead(group), isEmpty);
        await _expectGroupSummaryInStep(secrets, group);
      },
    );

    test(
      'recentChats reads no message record of a group that has not changed',
      () async {
        final base = MemorySecretStore();
        final secrets = _CountingSecrets(base);
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        await store.add(_groupMessage(group: group, author: bob));
        await ChatStore(secrets).recentChats();

        secrets.reads.clear();
        await ChatStore(secrets).recentChats();
        expect(
          secrets.reads,
          isNot(contains(ChatStore.groupMessagesKey(group))),
        );
        expect(secrets.reads, contains(ChatStore.groupSummaryKey(group)));
      },
    );

    test(
      'a group that is archived keeps its settings in step with its summary',
      () async {
        final secrets = MemorySecretStore();
        final store = ChatStore(secrets);
        await store.saveGroup(
          _groupOf(id: group, self: alice, others: [bob, carol]),
        );
        await store.add(_groupMessage(group: group, author: bob));
        await store.setMuted(group, true);

        final json = jsonDecode(
          (await secrets.read(ChatStore.groupSummaryKey(group)))!,
        ) as Map<String, dynamic>;
        expect(json['meta'], {
          'archived': false,
          'muted': true,
          'pinnedAt': null,
        });
        final chat = (await ChatStore(secrets).recentChats()).single;
        expect(chat.meta.muted, isTrue);
      },
    );

    test('deleting a group removes its record, messages, summary, settings and retention in one write', () async {
      final base = MemorySecretStore();
      final secrets = _CountingSecrets(base);
      final store = ChatStore(secrets);
      await store.saveGroup(
        _groupOf(id: group, self: alice, others: [bob, carol]),
      );
      await store.saveGroup(
        _groupOf(id: other, self: alice, others: [bob, carol]),
      );
      await store.add(_groupMessage(group: group, author: bob));
      await store.setMuted(group, true);
      await store.setRetention(group, const Duration(days: 1));
      secrets.batches.clear();

      await store.deleteChat(group);

      expect(secrets.batches, hasLength(1), reason: 'one write');
      final batch = secrets.batches.single;
      expect(
        batch.deleted,
        containsAll([
          ChatStore.groupKey(group),
          ChatStore.groupMessagesKey(group),
          ChatStore.groupSummaryKey(group),
          ChatStore.metaKey(group),
          '${ChatStore.retentionPrefix}$group',
        ]),
      );
      expect(batch.values.keys, [ChatStore.groupsIndexKey]);
      expect(await base.read(ChatStore.groupKey(group)), isNull);
      expect(await base.read(ChatStore.groupMessagesKey(group)), isNull);
      expect(await base.read(ChatStore.groupSummaryKey(group)), isNull);
      expect(await base.read(ChatStore.metaKey(group)), isNull);
      expect(await base.read('${ChatStore.retentionPrefix}$group'), isNull);
      expect([for (final g in await ChatStore(base).groups()) g.id], [other]);
      expect(
        [for (final c in await ChatStore(base).recentChats()) c.contactId],
        [other],
      );
      expect(await ChatStore(base).messages(group), isEmpty);
    });
  });
}
