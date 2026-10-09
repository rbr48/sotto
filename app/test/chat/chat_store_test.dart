import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_store.dart';
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
}
