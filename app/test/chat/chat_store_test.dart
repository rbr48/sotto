import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/file_storage.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity_store.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

ChatMessage _message(
  int n, {
  String contact = 'bob',
  bool outgoing = true,
  ChatState state = ChatState.delivered,
  String text = 'hi',
}) => ChatMessage(
  id: _id(n),
  contactId: contact,
  outgoing: outgoing,
  ts: 1700000000000 + n,
  text: text,
  state: state,
);

/// Checks that the summary record of [contactId] holds the last message and
/// unread count of its messages as they stand now. It reads the record
/// itself, so a summary that was never written cannot pass by being rebuilt.
Future<void> _expectSummaryInStep(
  MemorySecretStore secrets,
  String contactId,
) async {
  final list = await ChatStore(secrets).messages(contactId);
  final raw = await secrets.read(ChatStore.summaryKey(contactId));
  if (list.isEmpty) {
    expect(raw, isNull, reason: 'a chat with no messages has no summary');
    return;
  }
  expect(raw, isNotNull, reason: 'the summary of $contactId');
  final json = jsonDecode(raw!) as Map<String, dynamic>;
  expect(json['last'], list.last.toJson(), reason: 'last of $contactId');
  expect(
    json['unread'],
    list.where((m) => !m.outgoing && !m.read).length,
    reason: 'unread of $contactId',
  );
}

/// A [SecretStore] that keeps a record of every key read from it.
class _CountingSecrets implements SecretStore {
  _CountingSecrets(this._inner);

  final SecretStore _inner;
  final reads = <String>[];

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
  }) => _inner.writeAll(values, deleted: deleted);

  /// The keys of message records read so far.
  Iterable<String> get messageReads =>
      reads.where((key) => key.startsWith(ChatStore.contactKey('')));
}

/// A [SecretStore] whose writes to the keys [failOn] names fail, as a vault
/// file that cannot be written would.
class _FailingSecrets implements SecretStore {
  _FailingSecrets(this._inner);

  final SecretStore _inner;

  /// The keys whose writes fail; null for none.
  bool Function(String key)? failOn;

  void _check(String key) {
    final fails = failOn;
    if (fails != null && fails(key)) throw StateError('the write failed');
  }

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) async {
    _check(key);
    await _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    _check(key);
    await _inner.delete(key);
  }

  @override
  Future<void> writeAll(
    Map<String, String> values, {
    Iterable<String> deleted = const [],
  }) async {
    values.keys.followedBy(deleted).forEach(_check);
    await _inner.writeAll(values, deleted: deleted);
  }
}

void main() {
  late MemorySecretStore secrets;
  late ChatStore store;

  setUp(() {
    secrets = MemorySecretStore();
    store = ChatStore(secrets);
  });

  test('messages are kept in order, per contact', () async {
    await store.add(_message(1));
    await store.add(_message(2, contact: 'carol', outgoing: false));
    await store.add(_message(3));

    final bob = await store.messages('bob');
    expect(bob.map((m) => m.id), [_id(1), _id(3)]);
    expect((await store.messages('carol')).single.outgoing, isFalse);
    expect(await store.contactIds(), unorderedEquals(['bob', 'carol']));
  });

  test('a message is stored once, even when it arrives twice', () async {
    await store.add(_message(1));
    await store.add(_message(1));
    expect(await store.messages('bob'), hasLength(1));
    expect(await store.contains('bob', _id(1)), isTrue);
    expect(await store.contains('bob', _id(2)), isFalse);
  });

  test('state changes are saved', () async {
    await store.add(_message(1, state: ChatState.sending));
    await store.setState('bob', _id(1), ChatState.notSent);
    expect((await store.find('bob', _id(1)))!.state, ChatState.notSent);
  });

  test(
    'why a message was not sent is kept, and cleared when it is sent again',
    () async {
      await store.add(_message(1, state: ChatState.sending));
      await store.setState(
        'bob',
        _id(1),
        ChatState.notSent,
        reason: 'no-answer',
      );

      final unsent = (await ChatStore(secrets).messages('bob')).single;
      expect(unsent.state, ChatState.notSent);
      expect(unsent.reason, 'no-answer');

      await store.setState('bob', _id(1), ChatState.sending);
      expect((await store.find('bob', _id(1)))!.reason, isNull);
    },
  );

  test(
    'history survives a restart, read from the same encrypted store',
    () async {
      await store.add(_message(1, text: 'Salaam — مرحبا — নমস্কার'));
      final again = ChatStore(secrets);
      final restored = (await again.messages('bob')).single;
      expect(restored.text, 'Salaam — مرحبا — নমস্কার');
      expect(restored.state, ChatState.delivered);
      expect(restored.outgoing, isTrue);
    },
  );

  test('deleting a chat removes its messages and leaves the others', () async {
    await store.add(_message(1));
    await store.add(_message(2, contact: 'carol'));
    await store.deleteChat('bob');
    expect(await store.messages('bob'), isEmpty);
    expect(await store.contactIds(), ['carol']);
  });

  test('a chat with no messages is not listed', () async {
    await store.add(_message(1));
    await store.deleteChat('bob');
    expect(await store.contactIds(), isEmpty);
  });

  test('unreadable history is reported, and never overwritten', () async {
    await secrets.write(ChatStore.storageKey, '{not json');
    await expectLater(
      store.messages('bob'),
      throwsA(isA<ChatStoreException>()),
    );
    expect(await secrets.read(ChatStore.storageKey), '{not json');
  });

  test('a stored message with a wrong shape is reported, not guessed at', () async {
    await secrets.write(
      ChatStore.storageKey,
      '{"bob":[{"id":"${_id(1)}","out":true,"ts":"now","text":"x","state":"delivered"}]}',
    );
    await expectLater(
      store.messages('bob'),
      throwsA(isA<ChatStoreException>()),
    );
  });

  test('a stored message with an unknown state is reported', () async {
    await secrets.write(
      ChatStore.storageKey,
      '{"bob":[{"id":"${_id(1)}","out":true,"ts":1,"text":"x","state":"unknown"}]}',
    );
    await expectLater(
      store.messages('bob'),
      throwsA(isA<ChatStoreException>()),
    );
  });

  test('a voice note keeps its voice flag across a reload', () async {
    await store.add(
      ChatMessage(
        id: _id(7),
        contactId: 'bob',
        outgoing: false,
        ts: 1700000000007,
        text: 'voice-7.m4a',
        state: ChatState.received,
        fileId: _id(7),
        fileName: 'voice-7.m4a',
        fileMime: 'audio/mp4',
        fileStatus: 'completed',
        voiceNote: true,
      ),
    );
    await store.add(
      ChatMessage(
        id: _id(8),
        contactId: 'bob',
        outgoing: false,
        ts: 1700000000008,
        text: 'song.m4a',
        state: ChatState.received,
        fileId: _id(8),
        fileName: 'song.m4a',
        fileMime: 'audio/mp4',
        fileStatus: 'completed',
      ),
    );

    final reloaded = await ChatStore(secrets).messages('bob');

    expect(reloaded.firstWhere((m) => m.id == _id(7)).voiceNote, isTrue);
    expect(reloaded.firstWhere((m) => m.id == _id(8)).voiceNote, isFalse);
  });

  test('a message stored before the voice flag existed is not a voice note', () async {
    await secrets.write(
      ChatStore.storageKey,
      '{"bob":[{"id":"${_id(1)}","out":false,"ts":1,"text":"a.m4a","state":"received","fileName":"a.m4a","fileMime":"audio/mp4"}]}',
    );
    final loaded = await store.messages('bob');
    expect(loaded.single.voiceNote, isFalse);
  });

  test('a voice flag that is not a yes or no is reported, not guessed at', () async {
    await secrets.write(
      ChatStore.storageKey,
      '{"bob":[{"id":"${_id(1)}","out":true,"ts":1,"text":"x","state":"delivered","voiceNote":"yes"}]}',
    );
    await expectLater(
      store.messages('bob'),
      throwsA(isA<ChatStoreException>()),
    );
  });

  test('single message can be deleted', () async {
    await store.add(_message(1));
    await store.add(_message(2));
    expect(await store.messages('bob'), hasLength(2));

    await store.deleteMessage('bob', _id(1));
    final bob = await store.messages('bob');
    expect(bob.map((m) => m.id), [_id(2)]);
  });

  test('unread counts and markAsRead work as expected', () async {
    expect(await store.totalUnreadCount(), 0);

    // Incoming messages start unread by default when read is false
    final m1 = ChatMessage(
      id: _id(1),
      contactId: 'bob',
      outgoing: false,
      ts: 1000,
      text: 'hello',
      state: ChatState.received,
      read: false,
    );
    final m2 = ChatMessage(
      id: _id(2),
      contactId: 'bob',
      outgoing: false,
      ts: 2000,
      text: 'how are you?',
      state: ChatState.received,
      read: false,
    );
    final m3 = ChatMessage(
      id: _id(3),
      contactId: 'carol',
      outgoing: false,
      ts: 3000,
      text: 'hi from carol',
      state: ChatState.received,
      read: false,
    );

    await store.add(m1);
    await store.add(m2);
    await store.add(m3);

    expect(await store.totalUnreadCount(), 3);
    expect(await store.unreadCount('bob'), 2);
    expect(await store.unreadCount('carol'), 1);

    await store.markAsRead('bob');
    expect(await store.totalUnreadCount(), 1);
    expect(await store.unreadCount('bob'), 0);
    expect(await store.unreadCount('carol'), 1);

    // Outgoing messages don't add to unread count
    await store.add(_message(4, outgoing: true));
    expect(await store.totalUnreadCount(), 1);
  });

  test('changes stream notifies on store modifications', () async {
    var changeNotified = false;
    final sub = store.changes.listen((_) {
      changeNotified = true;
    });

    await store.add(_message(1));
    await Future<void>.delayed(Duration.zero);
    expect(changeNotified, isTrue);

    await sub.cancel();
  });

  test(
    'recentChats returns threads sorted by latest message timestamp',
    () async {
      final m1 = ChatMessage(
        id: _id(1),
        contactId: 'bob',
        outgoing: false,
        ts: 1000,
        text: 'early message',
        state: ChatState.received,
        read: false,
      );
      final m2 = ChatMessage(
        id: _id(2),
        contactId: 'carol',
        outgoing: true,
        ts: 5000,
        text: 'latest message',
        state: ChatState.queued,
        read: true,
      );

      await store.add(m1);
      await store.add(m2);

      final recent = await store.recentChats();
      expect(recent, hasLength(2));
      expect(recent.first.contactId, 'carol');
      expect(recent.first.lastMessage.state, ChatState.queued);
      expect(recent.first.unreadCount, 0);

      expect(recent.last.contactId, 'bob');
      expect(recent.last.unreadCount, 1);
    },
  );

  test(
    'markAsRead marks unread incoming messages and returns their IDs',
    () async {
      final m1 = ChatMessage(
        id: _id(1),
        contactId: 'bob',
        outgoing: false,
        ts: 1000,
        text: 'hello',
        state: ChatState.received,
        read: false,
      );
      final m2 = ChatMessage(
        id: _id(2),
        contactId: 'bob',
        outgoing: true,
        ts: 2000,
        text: 'reply',
        state: ChatState.delivered,
        read: true,
      );
      await store.add(m1);
      await store.add(m2);

      final readIds = await store.markAsRead('bob');
      expect(readIds, [_id(1)]);

      final after = await store.messages('bob');
      expect(after.first.read, isTrue);

      // Subsequent call returns empty list
      final again = await store.markAsRead('bob');
      expect(again, isEmpty);
    },
  );

  test('setState to ChatState.read persists correctly', () async {
    await store.add(_message(1, state: ChatState.delivered));
    await store.setState('bob', _id(1), ChatState.read);

    final msg = await store.find('bob', _id(1));
    expect(msg?.state, ChatState.read);

    // Verify survives store reload
    final fresh = ChatStore(secrets);
    final reloaded = await fresh.find('bob', _id(1));
    expect(reloaded?.state, ChatState.read);
  });

  test('retention settings and sweepExpired purge old messages', () async {
    final now = DateTime(2026, 10, 9, 12, 0, 0);
    // Message from 2 hours ago
    final oldMsg = ChatMessage(
      id: _id(1),
      contactId: 'bob',
      outgoing: false,
      ts: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
      text: 'old message',
      state: ChatState.received,
      read: true,
    );
    // Message from 10 minutes ago
    final newMsg = ChatMessage(
      id: _id(2),
      contactId: 'bob',
      outgoing: true,
      ts: now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
      text: 'new message',
      state: ChatState.delivered,
      read: true,
    );

    await store.add(oldMsg);
    await store.add(newMsg);

    // Setting a retention purges what is already too old, at once.
    await store.setRetention('bob', const Duration(hours: 1), clock: () => now);
    expect(await store.retention('bob'), const Duration(hours: 1));
    expect(await store.messageCount('bob'), 1);

    // Nothing is left for a later sweep to purge.
    final purged = await store.sweepExpired(clock: () => now);
    expect(purged, 0);

    final remaining = await store.messages('bob');
    expect(remaining, hasLength(1));
    expect(remaining.first.id, _id(2));
  });

  test(
    'legacy sotto.chats.v1 automatically migrates to decoupled keys',
    () async {
      // Write legacy monolithic format
      final legacyStore = MemorySecretStore();
      final legacyJson =
          '''
    {
      "alice": [{"id": "${_id(1)}", "out": true, "ts": 1000, "text": "hello alice", "state": "delivered"}],
      "bob": [{"id": "${_id(2)}", "out": false, "ts": 2000, "text": "hello me", "state": "received", "read": false}]
    }
    ''';
      await legacyStore.write(ChatStore.storageKey, legacyJson);

      final newStore = ChatStore(legacyStore);
      final aliceMsgs = await newStore.messages('alice');
      expect(aliceMsgs, hasLength(1));
      expect(aliceMsgs.first.text, 'hello alice');

      final bobMsgs = await newStore.messages('bob');
      expect(bobMsgs, hasLength(1));
      expect(bobMsgs.first.text, 'hello me');

      // Verify decoupled keys were written and legacy key was deleted
      expect(await legacyStore.read(ChatStore.storageKey), isNull);
      expect(await legacyStore.read(ChatStore.contactsIndexKey), isNotNull);
      expect(await legacyStore.read(ChatStore.contactKey('alice')), isNotNull);
      expect(await legacyStore.read(ChatStore.contactKey('bob')), isNotNull);
      expect(await newStore.contactIds(), unorderedEquals(['alice', 'bob']));
    },
  );

  test(
    'per-contact isolation: adding message only touches target contact key',
    () async {
      await store.add(_message(1, contact: 'alice'));
      await store.add(_message(2, contact: 'bob'));

      final aliceBefore = await secrets.read(ChatStore.contactKey('alice'));
      expect(aliceBefore, isNotNull);

      // Now add another message for Bob
      await store.add(_message(3, contact: 'bob'));

      // Alice's raw secret value must not change at all
      final aliceAfter = await secrets.read(ChatStore.contactKey('alice'));
      expect(aliceAfter, equals(aliceBefore));
    },
  );

  test('paginated messages returns windowed slices correctly', () async {
    for (var i = 1; i <= 25; i++) {
      await store.add(_message(i, contact: 'bob'));
    }

    expect(await store.messageCount('bob'), 25);

    // Limit 10, offset 0 -> 10 newest messages (16 to 25)
    final page1 = await store.messages('bob', limit: 10, offset: 0);
    expect(page1, hasLength(10));
    expect(page1.first.id, _id(16));
    expect(page1.last.id, _id(25));

    // Limit 10, offset 10 -> previous 10 messages (6 to 15)
    final page2 = await store.messages('bob', limit: 10, offset: 10);
    expect(page2, hasLength(10));
    expect(page2.first.id, _id(6));
    expect(page2.last.id, _id(15));

    // Limit 10, offset 20 -> remaining 5 oldest messages (1 to 5)
    final page3 = await store.messages('bob', limit: 10, offset: 20);
    expect(page3, hasLength(5));
    expect(page3.first.id, _id(1));
    expect(page3.last.id, _id(5));

    // Limit 10, offset 25 -> empty
    final page4 = await store.messages('bob', limit: 10, offset: 25);
    expect(page4, isEmpty);
  });

  test('searchAll finds messages across all contacts matching query', () async {
    await store.add(
      ChatMessage(
        id: _id(1),
        contactId: 'alice',
        outgoing: false,
        ts: 1000,
        text: 'Meeting at 3pm tomorrow',
        state: ChatState.received,
      ),
    );
    await store.add(
      ChatMessage(
        id: _id(2),
        contactId: 'bob',
        outgoing: true,
        ts: 2000,
        text: 'Sent the proposal document',
        fileName: 'project_proposal.pdf',
        state: ChatState.delivered,
      ),
    );
    await store.add(
      ChatMessage(
        id: _id(3),
        contactId: 'carol',
        outgoing: false,
        ts: 3000,
        text: 'Just saying hello',
        state: ChatState.received,
      ),
    );

    final searchMeeting = await store.searchAll('meeting');
    expect(searchMeeting, hasLength(1));
    expect(searchMeeting.first.contactId, 'alice');

    final searchProposal = await store.searchAll('proposal');
    expect(searchProposal, hasLength(1));
    expect(searchProposal.first.contactId, 'bob');

    final searchNone = await store.searchAll('xyz123');
    expect(searchNone, isEmpty);

    final searchEmpty = await store.searchAll('');
    expect(searchEmpty, isEmpty);
  });

  group('files the browser holds', () {
    ChatMessage file(int n, {bool voice = false}) => ChatMessage(
      id: _id(n),
      contactId: 'bob',
      outgoing: false,
      ts: n,
      text: 'f$n',
      state: ChatState.received,
      fileId: _id(n),
      fileName: voice ? 'voice.m4a' : 'f$n.bin',
      fileStatus: 'completed',
      filePath: 'web:${_id(n)}',
      voiceNote: voice,
    );

    test(
      'are held up to a total, and the least recently used go first',
      () async {
        final held = ChatStore(MemorySecretStore(), browserMemoryBytes: 300);
        held.rememberFile(_id(1), Uint8List(100));
        held.rememberFile(_id(2), Uint8List(100));
        held.rememberVoice(_id(3), Uint8List(100));
        expect(held.browserHeldBytes, 300);

        // Reading the first makes it the most recent, so the second goes.
        await held.readFile(file(1));
        held.rememberFile(_id(4), Uint8List(100));

        expect(held.browserHeldBytes, 300);
        expect(held.hasFile(file(1)), isTrue);
        expect(held.hasFile(file(2)), isFalse);
        expect(held.hasVoice(file(3, voice: true)), isTrue);
        expect(held.hasFile(file(4)), isTrue);
        // A file let go reads as no longer on this device.
        await expectLater(
          held.readFile(file(2)),
          throwsA(isA<ReceivedFileException>()),
        );
      },
    );

    test('a file larger than the total is still held, alone', () {
      final held = ChatStore(MemorySecretStore(), browserMemoryBytes: 150);
      held.rememberFile(_id(1), Uint8List(100));
      held.rememberFile(_id(2), Uint8List(200));
      expect(held.hasFile(file(1)), isFalse);
      expect(held.hasFile(file(2)), isTrue);
      expect(held.browserHeldBytes, 200);
    });

    test('forgetting a file frees its bytes', () {
      final held = ChatStore(MemorySecretStore());
      held.rememberFile(_id(1), Uint8List(100));
      held.rememberVoice(_id(2), Uint8List(50));
      held.forgetFile(_id(1));
      held.forgetVoice(_id(2));
      expect(held.browserHeldBytes, 0);
    });

    test('an outgoing file is kept once, with a web path', () async {
      final held = ChatStore(MemorySecretStore());
      final bytes = Uint8List.fromList([1, 2, 3]);
      final kept = await held.keepOutgoingFile(file(5), bytes);
      expect(kept.filePath, 'web:${_id(5)}');
      expect(await held.readFile(kept), bytes);

      final voice = await held.keepOutgoingFile(file(6, voice: true), bytes);
      expect(held.hasVoice(voice), isTrue);
      expect(held.browserHeldBytes, 6);
    });
  });

  group('replies, reactions, edits, deletes and pending controls', () {
    test('a record from before these fields loads with the defaults', () async {
      // Written by an earlier version: none of the new keys.
      await secrets.write(
        ChatStore.contactKey('bob'),
        '[{"id": "${_id(1)}", "out": true, "ts": 1000, "text": "hi", '
        '"state": "delivered", "read": true}]',
      );
      final message = (await ChatStore(secrets).messages('bob')).single;
      expect(message.replyTo, isNull);
      expect(message.reactions, isEmpty);
      expect(message.editedAt, isNull);
      expect(message.deletedForAll, isFalse);
      expect(message.forwarded, isFalse);
      // A message without the new fields saves without them too.
      expect(message.toJson().keys, isNot(contains('replyTo')));
      expect(message.toJson().keys, isNot(contains('reactions')));
      expect(message.toJson().keys, isNot(contains('editedAt')));
    });

    test('the new fields are saved and load again unchanged', () async {
      final first = ChatStore(secrets);
      await first.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 1000,
          text: 'edited text',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(2), text: 'the quote'),
          reactions: {'me': '\u{1F44D}', 'peer': '\u{2764}️'},
          editedAt: 2000,
          forwarded: true,
        ),
      );
      final loaded = (await ChatStore(secrets).messages('bob')).single;
      expect(loaded.replyTo, (id: _id(2), text: 'the quote'));
      expect(loaded.reactions, {'me': '\u{1F44D}', 'peer': '\u{2764}️'});
      expect(loaded.editedAt, 2000);
      expect(loaded.forwarded, isTrue);
      expect(loaded.deletedForAll, isFalse);

      await first.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: '', deletedForAll: true),
      );
      final deleted = (await ChatStore(secrets).messages('bob')).single;
      expect(deleted.deletedForAll, isTrue);
      expect(deleted.text, isEmpty);
      // A deleted message keeps no quote of its own: the text it quoted would
      // otherwise outlive the delete.
      expect(deleted.replyTo, isNull);
    });

    test('deleting a message for everyone takes its text out of every quote of it, and keeps the other quotes', () async {
      const door = 'the door code is 4471';
      // Message 1 is quoted by 2 and 3. It quotes message 6 itself, and 4
      // quotes a message that is not deleted.
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 1000,
          text: door,
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(6), text: 'an old quote'),
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: true,
          ts: 1001,
          text: 'got it',
          state: ChatState.delivered,
          replyTo: (id: _id(1), text: door),
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(3),
          contactId: 'bob',
          outgoing: false,
          ts: 1002,
          text: 'which door?',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(1), text: door),
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(4),
          contactId: 'bob',
          outgoing: false,
          ts: 1003,
          text: 'unrelated',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(9), text: 'other'),
        ),
      );

      expect(
        await store.changeMessage(
          'bob',
          _id(1),
          (m) => m.copyWith(text: '', deletedForAll: true, reactions: const {}),
        ),
        isTrue,
      );

      final reloaded = {
        for (final m in await ChatStore(secrets).messages('bob')) m.id: m,
      };
      expect(reloaded[_id(1)]!.deletedForAll, isTrue);
      expect(reloaded[_id(1)]!.replyTo, isNull);
      expect(reloaded[_id(2)]!.replyTo, (id: _id(1), text: ''));
      expect(reloaded[_id(2)]!.text, 'got it');
      expect(reloaded[_id(3)]!.replyTo, (id: _id(1), text: ''));
      expect(reloaded[_id(4)]!.replyTo, (id: _id(9), text: 'other'));
      expect(
        reloaded.values.any((m) => (m.replyTo?.text ?? '').contains('door')),
        isFalse,
      );
    });

    test('editing a message gives every quote of it the new text, and the old text is not kept', () async {
      const before = 'the door code is 4471';
      const after = 'the door code is 4472';
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: true,
          ts: 1000,
          text: before,
          state: ChatState.delivered,
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: 1001,
          text: 'got it',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(1), text: before),
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(3),
          contactId: 'bob',
          outgoing: true,
          ts: 1002,
          text: 'which door?',
          state: ChatState.delivered,
          replyTo: (id: _id(1), text: before),
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(4),
          contactId: 'bob',
          outgoing: false,
          ts: 1003,
          text: 'unrelated',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(9), text: 'other'),
        ),
      );

      expect(
        await store.changeMessage(
          'bob',
          _id(1),
          (m) => m.copyWith(text: after, editedAt: 2000),
        ),
        isTrue,
      );

      final reloaded = {
        for (final m in await ChatStore(secrets).messages('bob')) m.id: m,
      };
      expect(reloaded[_id(1)]!.text, after);
      expect(reloaded[_id(1)]!.editedAt, 2000);
      expect(reloaded[_id(2)]!.replyTo, (id: _id(1), text: after));
      expect(reloaded[_id(3)]!.replyTo, (id: _id(1), text: after));
      expect(reloaded[_id(4)]!.replyTo, (id: _id(9), text: 'other'));
      // Nothing of the old text is left in the stored record.
      expect(
        await secrets.read(ChatStore.contactKey('bob')),
        isNot(contains('4471')),
      );
    });

    test('a reply stored after its message was edited quotes the new text, and the old text is not kept', () async {
      const before = 'the door code is 4471';
      const after = 'the door code is 4472';
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: true,
          ts: 1000,
          text: before,
          state: ChatState.delivered,
        ),
      );
      await store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: after, editedAt: 2000),
      );

      // The reply arrives with the quote its sender had, the old text.
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: 1001,
          text: 'got it',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(1), text: before),
        ),
      );

      final reloaded = await ChatStore(secrets).find('bob', _id(2));
      expect(reloaded!.replyTo, (id: _id(1), text: after));
      expect(reloaded.text, 'got it');
      expect(
        await secrets.read(ChatStore.contactKey('bob')),
        isNot(contains('4471')),
      );
    });

    test('a reply stored after its message was deleted for everyone quotes no text, and a quote of an unknown message keeps its text', () async {
      const before = 'the door code is 4471';
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: true,
          ts: 1000,
          text: before,
          state: ChatState.delivered,
        ),
      );
      await store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: '', deletedForAll: true, reactions: const {}),
      );

      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: 1001,
          text: 'got it',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(1), text: before),
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(3),
          contactId: 'bob',
          outgoing: false,
          ts: 1002,
          text: 'and this',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(9), text: 'not stored here'),
        ),
      );

      final reloaded = {
        for (final m in await ChatStore(secrets).messages('bob')) m.id: m,
      };
      expect(reloaded[_id(2)]!.replyTo, (id: _id(1), text: ''));
      expect(reloaded[_id(3)]!.replyTo, (id: _id(9), text: 'not stored here'));
      expect(
        await secrets.read(ChatStore.contactKey('bob')),
        isNot(contains('4471')),
      );
    });

    test('a reply written while its message is being edited quotes the text the edit leaves', () async {
      const before = 'the door code is 4471';
      const after = 'the door code is 4472';
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: true,
          ts: 1000,
          text: before,
          state: ChatState.delivered,
        ),
      );

      // The edit is asked for first, then the reply, with the quote from before
      // the edit. The writes run in the order asked, so the reply is stored
      // with the edited text.
      final edit = store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: after, editedAt: 2000),
      );
      final reply = store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: 1001,
          text: 'got it',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(1), text: before),
        ),
      );
      await edit;
      await reply;

      final reloaded = await ChatStore(secrets).find('bob', _id(2));
      expect(reloaded!.replyTo, (id: _id(1), text: after));
    });

    test('the chat list and search order by this device\'s clock, so a peer\'s time cannot pin a chat to the top', () async {
      // Bob's clock is far ahead; his message arrived here a minute after
      // Carol's, which is dated earlier by her clock.
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 9999999999999,
          text: 'hello one',
          state: ChatState.received,
          read: false,
          arrivedAt: 1700000060000,
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'carol',
          outgoing: false,
          ts: 1700000030000,
          text: 'hello two',
          state: ChatState.received,
          read: false,
          arrivedAt: 1700000090000,
        ),
      );

      final recent = await store.recentChats();
      expect(recent.map((c) => c.contactId), ['carol', 'bob']);
      final found = await store.searchAll('hello');
      expect(found.map((m) => m.text), ['hello two', 'hello one']);
    });

    test(
      'a malformed reply, reaction or edit time is reported, not guessed',
      () async {
        for (final field in [
          '"replyTo": {"id": "${_id(2)}"}',
          '"reactions": {"someone": "\u{1F44D}"}',
          '"reactions": {"me": 5}',
          '"editedAt": "later"',
          '"deletedForAll": "yes"',
        ]) {
          await secrets.write(
            ChatStore.contactKey('bob'),
            '[{"id": "${_id(1)}", "out": true, "ts": 1000, "text": "hi", '
            '"state": "delivered", $field}]',
          );
          await expectLater(
            ChatStore(secrets).messages('bob'),
            throwsA(isA<ChatStoreException>()),
            reason: field,
          );
        }
      },
    );

    test('a reaction is set, replaced, and removed by an empty emoji', () {
      final base = _message(1, outgoing: false);
      final reacted = base.withReaction('peer', '\u{1F44D}');
      expect(reacted.reactions, {'peer': '\u{1F44D}'});
      expect(reacted.withReaction('peer', '\u{2764}').reactions, {
        'peer': '\u{2764}',
      });
      expect(reacted.withReaction('me', '\u{1F44D}').reactions, {
        'peer': '\u{1F44D}',
        'me': '\u{1F44D}',
      });
      expect(reacted.withReaction('peer', '').reactions, isEmpty);
      // The message it came from is not changed.
      expect(base.reactions, isEmpty);
    });

    test('changeMessage changes a stored message, or leaves it', () async {
      await store.add(_message(1, outgoing: false));
      expect(
        await store.changeMessage(
          'bob',
          _id(1),
          (m) => m.copyWith(text: 'new'),
        ),
        isTrue,
      );
      expect((await store.find('bob', _id(1)))!.text, 'new');
      expect(await store.changeMessage('bob', _id(1), (_) => null), isFalse);
      expect(
        await store.changeMessage('bob', _id(9), (m) => m.copyWith(text: 'x')),
        isFalse,
      );
    });

    test(
      'a reaction replaces the pending reaction on the same message',
      () async {
        await store.queueControl(
          'bob',
          ReactFrame(id: _id(1), emoji: '\u{1F44D}', ts: 1),
        );
        await store.queueControl(
          'bob',
          ReactFrame(id: _id(1), emoji: '\u{2764}', ts: 2),
        );
        final pending = await store.pendingControls('bob');
        expect(pending.single, isA<ReactFrame>());
        expect((pending.single as ReactFrame).emoji, '\u{2764}');
      },
    );

    test('an edit and a reaction on one message are both kept, and a delete replaces both', () async {
      await store.queueControl(
        'bob',
        EditFrame(id: _id(1), ts: 1, text: 'new'),
      );
      await store.queueControl(
        'bob',
        ReactFrame(id: _id(1), emoji: '\u{1F44D}', ts: 2),
      );
      expect(await store.pendingControls('bob'), hasLength(2));

      await store.queueControl('bob', DeleteFrame(id: _id(1), ts: 3));
      final pending = await store.pendingControls('bob');
      expect(pending.single, isA<DeleteFrame>());
      expect(pending.single.id, _id(1));
    });

    test(
      'pending controls on other messages are kept, in the order made',
      () async {
        await store.queueControl(
          'bob',
          ReactFrame(id: _id(1), emoji: '\u{1F44D}', ts: 1),
        );
        await store.queueControl(
          'bob',
          ReactFrame(id: _id(2), emoji: '\u{1F44D}', ts: 2),
        );
        await store.queueControl(
          'bob',
          EditFrame(id: _id(1), ts: 3, text: 'a'),
        );
        final pending = await store.pendingControls('bob');
        expect(pending.map((c) => c.id), [_id(1), _id(2), _id(1)]);
      },
    );

    test('past the limit, the oldest pending control is dropped', () async {
      const limit = ChatStore.maxPendingControls;
      for (var i = 1; i <= limit + 5; i++) {
        await store.queueControl(
          'bob',
          ReactFrame(id: _id(i), emoji: '\u{1F44D}', ts: i),
        );
      }
      final pending = await store.pendingControls('bob');
      expect(pending, hasLength(limit));
      expect(pending.first.id, _id(6));
      expect(pending.last.id, _id(limit + 5));
    });

    test(
      'a sent control is taken off, but a newer one for the message stays',
      () async {
        final sent = ReactFrame(id: _id(1), emoji: '\u{1F44D}', ts: 1);
        await store.queueControl('bob', sent);
        final newer = ReactFrame(id: _id(1), emoji: '\u{2764}', ts: 2);
        await store.queueControl('bob', newer);

        // The older one was replaced before it was sent: nothing is removed.
        await store.removeControl('bob', sent);
        expect((await store.pendingControls('bob')).single, isA<ReactFrame>());
        expect(
          ((await store.pendingControls('bob')).single as ReactFrame).emoji,
          '\u{2764}',
        );

        await store.removeControl('bob', newer);
        expect(await store.pendingControls('bob'), isEmpty);
      },
    );

    test(
      'pending controls survive a reload, and a deleted chat takes them',
      () async {
        await store.queueControl(
          'bob',
          EditFrame(id: _id(1), ts: 5, text: 'later'),
        );
        final reloaded = ChatStore(secrets);
        expect(
          ((await reloaded.pendingControls('bob')).single as EditFrame).text,
          'later',
        );
        await reloaded.deleteChat('bob');
        expect(await ChatStore(secrets).pendingControls('bob'), isEmpty);
      },
    );

    test(
      'pending controls that cannot be read are reported, not guessed at',
      () async {
        await secrets.write(
          ChatStore.pendingKey('bob'),
          r'["{\"t\":\"msg\"}"]',
        );
        await expectLater(
          store.pendingControls('bob'),
          throwsA(isA<ChatStoreException>()),
        );
      },
    );
  });

  group('summary records', () {
    test(
      'add keeps the summary in step, and a message stored twice leaves it',
      () async {
        await store.add(
          ChatMessage(
            id: _id(1),
            contactId: 'bob',
            outgoing: false,
            ts: 1000,
            text: 'hello',
            state: ChatState.received,
            read: false,
          ),
        );
        await _expectSummaryInStep(secrets, 'bob');
        await store.add(_message(2));
        await _expectSummaryInStep(secrets, 'bob');
        final before = await secrets.read(ChatStore.summaryKey('bob'));
        await store.add(_message(2));
        expect(await secrets.read(ChatStore.summaryKey('bob')), before);
      },
    );

    test('updateMessage keeps the summary in step, for the last message and for an earlier one', () async {
      await store.add(_message(1, outgoing: false));
      await store.add(_message(2));
      await store.updateMessage(
        _message(2).copyWith(reactions: {'peer': '\u{1F44D}'}),
      );
      await _expectSummaryInStep(secrets, 'bob');
      await store.updateMessage(
        _message(1, outgoing: false).copyWith(text: 'x'),
      );
      await _expectSummaryInStep(secrets, 'bob');
    });

    test(
      'setState keeps the summary in step, with its state and reason',
      () async {
        await store.add(_message(1, state: ChatState.sending));
        await store.setState(
          'bob',
          _id(1),
          ChatState.notSent,
          reason: 'no-answer',
        );
        await _expectSummaryInStep(secrets, 'bob');
        final json = jsonDecode(
          (await secrets.read(ChatStore.summaryKey('bob')))!,
        ) as Map<String, dynamic>;
        expect((json['last'] as Map)['state'], 'notSent');
        expect((json['last'] as Map)['reason'], 'no-answer');
      },
    );

    test('a quote refresh keeps the summary in step, when the quoted message is edited or deleted', () async {
      const before = 'the door code is 4471';
      const after = 'the door code is 4472';
      await store.add(_message(1, text: before));
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: 1001,
          text: 'got it',
          state: ChatState.received,
          read: false,
          replyTo: (id: _id(1), text: before),
        ),
      );

      await store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: after, editedAt: 2000),
      );
      await _expectSummaryInStep(secrets, 'bob');
      final edited = jsonDecode(
        (await secrets.read(ChatStore.summaryKey('bob')))!,
      ) as Map<String, dynamic>;
      expect(((edited['last'] as Map)['replyTo'] as Map)['text'], after);

      await store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: '', deletedForAll: true),
      );
      await _expectSummaryInStep(secrets, 'bob');
      final deleted = jsonDecode(
        (await secrets.read(ChatStore.summaryKey('bob')))!,
      ) as Map<String, dynamic>;
      expect(((deleted['last'] as Map)['replyTo'] as Map)['text'], '');
    });

    test('markAsRead keeps the unread count in step', () async {
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 1000,
          text: 'one',
          state: ChatState.received,
          read: false,
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: 1001,
          text: 'two',
          state: ChatState.received,
          read: false,
        ),
      );
      await _expectSummaryInStep(secrets, 'bob');

      await store.markAsRead('bob');
      await _expectSummaryInStep(secrets, 'bob');
      final json = jsonDecode(
        (await secrets.read(ChatStore.summaryKey('bob')))!,
      ) as Map<String, dynamic>;
      expect(json['unread'], 0);
    });

    test('deleting messages keeps the summary in step, down to none', () async {
      await store.add(_message(1));
      await store.add(_message(2));
      await store.add(_message(3));

      await store.deleteMessage('bob', _id(3));
      await _expectSummaryInStep(secrets, 'bob');
      await store.deleteMessage('bob', _id(1));
      await _expectSummaryInStep(secrets, 'bob');
      await store.deleteMessage('bob', _id(2));
      await _expectSummaryInStep(secrets, 'bob');
      expect(await secrets.read(ChatStore.summaryKey('bob')), isNull);
    });

    test('the sweep keeps the summary in step, down to none', () async {
      final now = DateTime(2026, 10, 9, 12, 0, 0);
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
          text: 'old',
          state: ChatState.received,
          read: false,
        ),
      );
      await store.add(
        ChatMessage(
          id: _id(2),
          contactId: 'bob',
          outgoing: false,
          ts: now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
          text: 'new',
          state: ChatState.received,
          read: false,
        ),
      );

      await store.setRetention(
        'bob',
        const Duration(hours: 1),
        clock: () => now,
      );
      await _expectSummaryInStep(secrets, 'bob');
      final json = jsonDecode(
        (await secrets.read(ChatStore.summaryKey('bob')))!,
      ) as Map<String, dynamic>;
      expect((json['last'] as Map)['id'], _id(2));
      expect(json['unread'], 1);

      await store.sweepExpired(clock: () => now.add(const Duration(hours: 1)));
      await _expectSummaryInStep(secrets, 'bob');
      expect(await secrets.read(ChatStore.summaryKey('bob')), isNull);
    });

    test('deleting a chat removes its summary record', () async {
      await store.add(_message(1));
      await store.add(_message(2, contact: 'carol'));
      expect(await secrets.read(ChatStore.summaryKey('bob')), isNotNull);

      await store.deleteChat('bob');
      expect(await secrets.read(ChatStore.summaryKey('bob')), isNull);
      expect(await secrets.read(ChatStore.summaryKey('carol')), isNotNull);
    });
  });

  group('the chat list reads summary records', () {
    test('it reads no message record of a chat that has not changed', () async {
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 1000,
          text: 'hello',
          state: ChatState.received,
          read: false,
        ),
      );
      await store.add(_message(2, contact: 'carol'));
      final counting = _CountingSecrets(secrets);
      final list = ChatStore(counting);

      final recent = await list.recentChats();
      expect(recent.map((c) => c.contactId), ['carol', 'bob']);
      expect(recent.last.unreadCount, 1);
      expect(counting.messageReads, isEmpty);
      expect(
        counting.reads,
        containsAll([
          ChatStore.summaryKey('bob'),
          ChatStore.summaryKey('carol'),
        ]),
      );

      counting.reads.clear();
      expect(await list.totalUnreadCount(), 1);
      expect(counting.messageReads, isEmpty);
    });

    test('an old vault with no summary records gets them once, with the chats and unread counts the new code writes', () async {
      // The vault as an earlier version left it: message records and the
      // index, and no summary records.
      final fixture = <String, List<Map<String, dynamic>>>{
        'alice': [
          {
            'id': _id(1),
            'out': true,
            'ts': 1000,
            'text': 'hello alice',
            'state': 'delivered',
          },
          {
            'id': _id(2),
            'out': false,
            'ts': 2000,
            'text': 'hi back',
            'state': 'received',
            'read': false,
          },
        ],
        'bob': [
          {
            'id': _id(3),
            'out': false,
            'ts': 3000,
            'text': 'one',
            'state': 'received',
            'read': false,
          },
          {
            'id': _id(4),
            'out': false,
            'ts': 4000,
            'text': 'two',
            'state': 'received',
            'read': false,
          },
          {
            'id': _id(5),
            'out': true,
            'ts': 3500,
            'text': 'three',
            'state': 'delivered',
          },
        ],
        'carol': [
          {
            'id': _id(6),
            'out': true,
            'ts': 500,
            'text': 'x',
            'state': 'read',
            'read': true,
          },
        ],
      };
      final old = MemorySecretStore();
      for (final entry in fixture.entries) {
        await old.write(
          ChatStore.contactKey(entry.key),
          jsonEncode(entry.value),
        );
      }
      await old.write(
        ChatStore.contactsIndexKey,
        jsonEncode(fixture.keys.toList()),
      );

      // The same chats written by the new code.
      final written = MemorySecretStore();
      final fresh = ChatStore(written);
      for (final entry in fixture.entries) {
        for (final item in entry.value) {
          await fresh.add(ChatMessage.fromJson(entry.key, item));
        }
      }

      final rebuilt = ChatStore(old);
      final fromOld = await rebuilt.recentChats();
      // The last message is the last one stored, not the latest by time.
      expect(
        [
          for (final c in fromOld)
            (c.contactId, c.lastMessage.id, c.unreadCount),
        ],
        [('bob', _id(5), 2), ('alice', _id(2), 1), ('carol', _id(6), 0)],
      );
      expect(await rebuilt.totalUnreadCount(), 3);

      final fromNew = await ChatStore(written).recentChats();
      expect(
        [
          for (final c in fromNew)
            (c.contactId, c.lastMessage.id, c.unreadCount),
        ],
        [
          for (final c in fromOld)
            (c.contactId, c.lastMessage.id, c.unreadCount),
        ],
      );
      for (final contactId in fixture.keys) {
        expect(
          await old.read(ChatStore.summaryKey(contactId)),
          await written.read(ChatStore.summaryKey(contactId)),
          reason: contactId,
        );
      }

      // Rebuilt once: the next lists read no message record.
      final counting = _CountingSecrets(old);
      await ChatStore(counting).recentChats();
      await ChatStore(counting).totalUnreadCount();
      expect(counting.messageReads, isEmpty);
    });

    test('a summary record that cannot be read is reported, its chat is skipped, and the other chats still load', () async {
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 1000,
          text: 'one',
          state: ChatState.received,
          read: false,
        ),
      );
      await store.add(_message(2, contact: 'carol'));
      final valid = jsonEncode(_message(3).toJson());
      final unreadTooMany = '{"last": $valid, "unread": "1"}';
      final unknownLast = '{"last": "not a message", "unread": 1}';
      final negative = '{"last": $valid, "unread": -1}';
      for (final raw in [
        'not json',
        '[]',
        unknownLast,
        unreadTooMany,
        negative,
      ]) {
        await secrets.write(ChatStore.summaryKey('bob'), raw);
        final list = ChatStore(secrets);

        await expectLater(
          list.threadSummary('bob'),
          throwsA(isA<ChatStoreException>()),
          reason: raw,
        );
        final recent = await list.recentChats();
        expect(recent.map((c) => c.contactId), ['carol'], reason: raw);
        expect(await list.totalUnreadCount(), 0, reason: raw);
        expect(await secrets.read(ChatStore.summaryKey('bob')), raw);
        expect((await list.messages('bob')).single.text, 'one', reason: raw);
      }
    });

    test(
      'an unread count is read from the summary record, not the messages',
      () async {
        await store.add(
          ChatMessage(
            id: _id(1),
            contactId: 'bob',
            outgoing: false,
            ts: 1000,
            text: 'hello',
            state: ChatState.received,
            read: false,
          ),
        );
        final counting = _CountingSecrets(secrets);

        expect(await ChatStore(counting).unreadCount('bob'), 1);
        expect(counting.messageReads, isEmpty);
        expect(await ChatStore(counting).unreadCount('nobody'), 0);
      },
    );

    test('an unreadable summary record is reported once, and its chat stays out of the list', () async {
      await store.add(_message(1));
      await secrets.write(ChatStore.summaryKey('bob'), 'not json');
      final events = <String>[];
      final list = ChatStore(secrets, log: events.add);

      expect(await list.recentChats(), isEmpty);
      expect(await list.totalUnreadCount(), 0);
      expect(await list.recentChats(), isEmpty);
      expect(events, ['chat summary cannot be read']);
    });

    test('a summary record that cannot be saved does not stop the list, and is reported once', () async {
      // A chat as an earlier version left it: its messages, and no summary.
      await store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: 1000,
          text: 'hello',
          state: ChatState.received,
          read: false,
        ),
      );
      await secrets.delete(ChatStore.summaryKey('bob'));
      final failing = _FailingSecrets(secrets)
        ..failOn = (key) => key == ChatStore.summaryKey('bob');
      final events = <String>[];
      final list = ChatStore(failing, log: events.add);

      final recent = await list.recentChats();
      expect(recent.map((c) => c.contactId), ['bob']);
      expect(recent.single.lastMessage.id, _id(1));
      expect(recent.single.unreadCount, 1);
      expect(await list.totalUnreadCount(), 1);
      expect(events, ['chat summary cannot be saved']);
    });
  });

  group('a failed write leaves the stored chat as it was', () {
    late _FailingSecrets failing;

    setUp(() {
      failing = _FailingSecrets(secrets);
    });

    test(
      'a failed add stores nothing, and the same store and a fresh one agree',
      () async {
        await store.add(_message(1));
        failing.failOn = (key) => key == ChatStore.summaryKey('bob');
        final same = ChatStore(failing);

        await expectLater(same.add(_message(2)), throwsStateError);
        expect((await same.messages('bob')).map((m) => m.id), [_id(1)]);
        expect((await ChatStore(secrets).messages('bob')).map((m) => m.id), [
          _id(1),
        ]);
        await _expectSummaryInStep(secrets, 'bob');
        expect(
          (await ChatStore(secrets).recentChats()).single.lastMessage.id,
          _id(1),
        );

        // A later change on the same store keeps the chat as it stands.
        failing.failOn = null;
        await same.add(_message(3));
        expect((await ChatStore(secrets).messages('bob')).map((m) => m.id), [
          _id(1),
          _id(3),
        ]);
        await _expectSummaryInStep(secrets, 'bob');
      },
    );

    test('a failed delete of the last message keeps the message', () async {
      await store.add(_message(1));
      failing.failOn = (key) => key == ChatStore.summaryKey('bob');

      await expectLater(
        ChatStore(failing).deleteMessage('bob', _id(1)),
        throwsStateError,
      );
      expect((await ChatStore(secrets).messages('bob')).map((m) => m.id), [
        _id(1),
      ]);
      await _expectSummaryInStep(secrets, 'bob');
    });

    test(
      'a failed delete of a chat leaves the chat whole, in the list',
      () async {
        await store.add(_message(1));
        failing.failOn = (key) => key == ChatStore.summaryKey('bob');

        await expectLater(
          ChatStore(failing).deleteChat('bob'),
          throwsStateError,
        );
        final fresh = ChatStore(secrets);
        expect((await fresh.messages('bob')).map((m) => m.id), [_id(1)]);
        expect((await fresh.recentChats()).map((c) => c.contactId), ['bob']);
        await _expectSummaryInStep(secrets, 'bob');
      },
    );
  });
}
