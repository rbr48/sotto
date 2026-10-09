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
    expect(changeNotified, isTrue);

    await sub.cancel();
  });
}
