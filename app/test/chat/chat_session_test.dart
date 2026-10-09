import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity_store.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

/// One end of an in-memory data channel. Frames sent here arrive at [peer].
class _Link implements ChatTransport {
  final _incoming = StreamController<String>();
  _Link? peer;
  bool connected = true;
  bool closed = false;

  @override
  bool send(String frame) {
    if (closed || !connected || peer == null || peer!.closed) return false;
    peer!._incoming.add(frame);
    return true;
  }

  @override
  Stream<String> get frames => _incoming.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

(_Link, _Link) _pair() {
  final a = _Link();
  final b = _Link();
  a.peer = b;
  b.peer = a;
  return (a, b);
}

/// Lets queued events and futures run.
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Side {
  _Side(
    this.name,
    this.contact,
    this.link, {
    required this.clock,
    ChatStore? sharedStore,
  }) : secrets = MemorySecretStore() {
    // A later session on the same device keeps the same history.
    store = sharedStore ?? ChatStore(secrets);
  }

  final String name;
  final String contact;
  final _Link link;
  final MemorySecretStore secrets;
  late final ChatStore store;
  final DateTime Function() clock;
  late ChatSession session;
  final events = <ChatSessionEvent>[];
  int _ids = 0;

  void start({List<ChatMessage> resend = const []}) {
    session = ChatSession(
      contactId: contact,
      transport: link,
      store: store,
      clock: clock,
      newId: () => _id(100 + (_ids++)),
    );
    session.events.listen(events.add);
    unawaited(session.start(resend: resend));
  }

  Iterable<T> ofType<T extends ChatSessionEvent>() => events.whereType<T>();
}

void main() {
  late DateTime now;
  DateTime clock() => now;

  setUp(() {
    now = DateTime.utc(2026, 10, 9, 12);
  });

  test('a message is delivered and marked delivered on both sides', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    final sent = await alice.session.sendText('Salaam');
    await _settle();

    expect(
      (await alice.store.find('bob', sent.id))!.state,
      ChatState.delivered,
    );
    final received = (await bob.store.messages('alice')).single;
    expect(received.text, 'Salaam');
    expect(received.outgoing, isFalse);
    expect(received.state, ChatState.received);
    expect(alice.ofType<MessageDelivered>().single.id, sent.id);
    expect(bob.ofType<MessageReceived>().single.message.text, 'Salaam');
  });

  test('text is cleaned before it is stored and sent', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    await alice.session.sendText('  hi\u0000 \u202E there ');
    await _settle();

    expect((await bob.store.messages('alice')).single.text, 'hi  there');
  });

  test('messages wait until the other side has said hello', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    await _settle();

    // Bob is not running yet, so nothing can be sent.
    final sent = await alice.session.sendText('early');
    await _settle();
    expect(alice.session.isReady, isFalse);
    expect((await alice.store.find('bob', sent.id))!.state, ChatState.sending);

    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    expect(
      (await alice.store.find('bob', sent.id))!.state,
      ChatState.delivered,
    );
    expect((await bob.store.messages('alice')).single.text, 'early');
  });

  test(
    'a message that arrives twice is stored once, but acknowledged each time',
    () async {
      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      final frame = ChatFrames.encode(
        MessageFrame(id: _id(7), ts: now.millisecondsSinceEpoch, text: 'once'),
      );
      a.send(frame);
      a.send(frame);
      await _settle();

      expect(await bob.store.messages('alice'), hasLength(1));
      expect(bob.ofType<MessageReceived>(), hasLength(1));
    },
  );

  test(
    'a session that breaks marks unacknowledged messages not sent',
    () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      a.connected = false;
      final sent = await alice.session.sendText('lost in transit');
      await _settle();

      expect(alice.session.isEnded, isTrue);
      expect(
        (await alice.store.find('bob', sent.id))!.state,
        ChatState.notSent,
      );
      expect(alice.ofType<MessageNotSent>().single.id, sent.id);
      expect(alice.ofType<SessionEnded>().single.reason, 'lost');
      expect(await bob.store.messages('alice'), isEmpty);
    },
  );

  test('a not-sent message goes out in the next session', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();
    a.connected = false;
    final sent = await alice.session.sendText('again');
    await _settle();
    final unsent = (await alice.store.find('bob', sent.id))!;

    final (c, d) = _pair();
    final alice2 = _Side(
      'alice',
      'bob',
      c,
      clock: clock,
      sharedStore: alice.store,
    )..start(resend: [unsent]);
    final bob2 = _Side('bob', 'alice', d, clock: clock, sharedStore: bob.store)
      ..start();
    await _settle();

    expect(
      (await alice2.store.find('bob', sent.id))!.state,
      ChatState.delivered,
    );
    expect((await bob2.store.messages('alice')).single.text, 'again');
    expect(bob.session.isEnded, isFalse);
  });

  test('a bye from the other side ends the session with its reason', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    await alice.session.close();
    await _settle();

    expect(alice.ofType<SessionEnded>().single.reason, 'closed');
    expect(bob.ofType<SessionEnded>().single.reason, 'bye');
    expect(bob.session.isEnded, isTrue);
  });

  test('a session with another protocol version ends at once', () async {
    final (a, b) = _pair();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();
    // Bob hears a hello from another version.
    a.send('{"t":"hello","v":2}');
    await _settle();
    expect(bob.ofType<SessionEnded>().single.reason, 'version');
  });

  test('malformed frames are ignored and the session goes on', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    b.peer!.send('garbage');
    b.peer!.send('{"t":"msg"}');
    await _settle();
    expect(bob.session.isEnded, isFalse);

    await alice.session.sendText('still here');
    await _settle();
    expect((await bob.store.messages('alice')).single.text, 'still here');
  });

  test(
    'an idle session closes after five minutes, unless the chat is open',
    () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      now = now.add(const Duration(minutes: 4));
      await alice.session.tick(viewing: false);
      expect(alice.session.isEnded, isFalse);

      now = now.add(const Duration(minutes: 1));
      await alice.session.tick(viewing: true);
      expect(alice.session.isEnded, isFalse);

      await alice.session.tick(viewing: false);
      await _settle();
      expect(alice.ofType<SessionEnded>().single.reason, 'idle');
      expect(bob.ofType<SessionEnded>().single.reason, 'bye');
    },
  );

  test(
    'empty text is refused, and a session that has ended takes no messages',
    () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      await expectLater(
        alice.session.sendText('  \u0000 '),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        alice.session.sendText('x' * (maxTextChars + 1)),
        throwsA(isA<ArgumentError>()),
      );

      await alice.session.close();
      await _settle();
      expect(() => alice.session.sendText('late'), throwsStateError);
      expect(bob.session.isEnded, isTrue);
    },
  );
}
