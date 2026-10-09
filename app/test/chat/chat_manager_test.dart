import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_rtc.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/identity_store.dart';

/// A connection that links to its peer when the answer is applied, the way
/// a real one connects once the SDP is exchanged.
class _FakeRtc implements ChatRtc {
  _FakeRtc(this.registry, {this.neverOpens = false});

  final Map<String, _FakeRtc> registry;
  final bool neverOpens;
  bool relayOnly = false;
  bool closed = false;
  final addedCandidates = <Map<String, dynamic>>[];

  final _frames = StreamController<String>();
  final _binaryFrames = StreamController<Uint8List>();
  final _opened = Completer<void>();
  final _lost = Completer<void>();
  final _candidates = StreamController<Map<String, Object?>>.broadcast();
  _FakeRtc? peer;
  bool _open = false;
  late final ChatTransport _transport = _FakeTransport(this);

  @override
  ChatTransport get transport => _transport;

  @override
  Future<void> get opened => _opened.future;

  @override
  Future<void> get lost => _lost.future;

  @override
  Stream<Map<String, Object?>> get localCandidates => _candidates.stream;

  @override
  Future<String> createOffer() async {
    final sdp = 'offer-${identityHashCode(this)}';
    registry[sdp] = this;
    scheduleMicrotask(
      () => _candidates.add({
        'candidate': 'candidate:$sdp',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      }),
    );
    return sdp;
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    final offerer = registry[sdp];
    if (offerer == null) throw StateError('no such offer');
    if (!neverOpens) _link(offerer);
    return 'answer-$sdp';
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    if (peer == null && !neverOpens) throw StateError('no link yet');
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {
    addedCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closed = true;
    _markLost();
    if (!_frames.isClosed) await _frames.close();
    if (!_binaryFrames.isClosed) await _binaryFrames.close();
    if (!_candidates.isClosed) await _candidates.close();
  }

  void _link(_FakeRtc other) {
    peer = other;
    other.peer = this;
    _markOpen();
    other._markOpen();
  }

  void _markOpen() {
    _open = true;
    if (!_opened.isCompleted) _opened.complete();
  }

  void _markLost() {
    if (!_lost.isCompleted) _lost.complete();
  }
}

class _FakeTransport implements ChatTransport {
  _FakeTransport(this.owner);

  final _FakeRtc owner;

  @override
  bool send(String frame) {
    final peer = owner.peer;
    if (!owner._open || peer == null || owner.closed) return false;
    scheduleMicrotask(() {
      if (!peer.closed && !peer._frames.isClosed) peer._frames.add(frame);
    });
    return true;
  }

  @override
  bool sendBinary(Uint8List data) {
    final peer = owner.peer;
    if (!owner._open || peer == null || owner.closed) return false;
    scheduleMicrotask(() {
      if (!peer.closed && !peer._binaryFrames.isClosed) {
        peer._binaryFrames.add(data);
      }
    });
    return true;
  }

  @override
  Stream<String> get frames => owner._frames.stream;

  @override
  Stream<Uint8List> get binaryFrames => owner._binaryFrames.stream;

  @override
  Future<void> close() async {
    if (!owner._frames.isClosed) await owner._frames.close();
    if (!owner._binaryFrames.isClosed) await owner._binaryFrames.close();
  }
}

/// Delivers envelopes between devices, one microtask later, as a relay does.
class _Network {
  final managers = <String, List<ChatManager>>{};
  final registry = <String, _FakeRtc>{};
  final rtcs = <String, List<_FakeRtc>>{};
  final sent = <({String from, String to, String type})>[];

  void deliver(
    String from,
    String to,
    String type,
    Map<String, Object?> body,
    String? callId,
  ) {
    sent.add((from: from, to: to, type: type));
    for (final device in managers[to] ?? const <ChatManager>[]) {
      scheduleMicrotask(
        () => device.handle(
          from: from,
          type: type,
          body: Map<String, dynamic>.from(body),
          callId: callId,
        ),
      );
    }
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 300; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A store whose writes take a while, as a real vault's can.
class _SlowSecrets implements SecretStore {
  _SlowSecrets(this.delay);

  final Duration delay;
  final _inner = MemorySecretStore();

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) async {
    await Future<void>.delayed(delay);
    await _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);
}

void main() {
  late _Network net;
  late DateTime now;
  final managers = <ChatManager>[];

  setUp(() {
    net = _Network();
    now = DateTime.utc(2026, 10, 9, 12);
    managers.clear();
  });

  tearDown(() async {
    for (final manager in managers) {
      await manager.dispose();
    }
  });

  /// One device of the identity [myId]. Every device of a person shares the
  /// identity id; it is how the other side knows who is writing.
  ChatManager device(
    String myId, {
    required Set<String> contacts,
    bool hideIp = false,
    bool failCreate = false,
    bool neverOpens = false,
    Duration connectTimeout = const Duration(milliseconds: 200),
    ChatStore? store,
    List<Map<String, dynamic>>? servers,
  }) {
    final manager = ChatManager(
      myId: myId,
      store: store ?? ChatStore(MemorySecretStore()),
      isContact: contacts.contains,
      send: (to, type, body, callId) =>
          net.deliver(myId, to, type, body, callId),
      iceServers: () async =>
          servers ??
          [
            {'urls': 'stun:stun.test'},
            {'urls': 'turn:turn.test', 'username': 'u', 'credential': 'c'},
          ],
      hideIp: () => hideIp,
      createRtc: ({required iceServers, required relayOnly}) async {
        if (failCreate) throw StateError('no network');
        final rtc = _FakeRtc(net.registry, neverOpens: neverOpens)
          ..relayOnly = relayOnly;
        (net.rtcs[myId] ??= []).add(rtc);
        return rtc;
      },
      clock: () => now,
      connectTimeout: connectTimeout,
    );
    managers.add(manager);
    (net.managers[myId] ??= []).add(manager);
    return manager;
  }

  test('messages go both ways and are marked delivered', () async {
    final aliceStore = ChatStore(MemorySecretStore());
    final bobStore = ChatStore(MemorySecretStore());
    final alice = device('alice', contacts: {'bob'}, store: aliceStore);
    device('bob', contacts: {'alice'}, store: bobStore);

    // Typed before the chat is open: it goes out once the chat is ready.
    final first = await alice.sendText('bob', 'Salaam');
    await _settle();
    final second = await alice.sendText('bob', 'second');
    await _settle();

    final received = await bobStore.messages('alice');
    expect(received.map((m) => m.text), ['Salaam', 'second']);
    expect(received.every((m) => !m.outgoing), isTrue);
    expect(
      (await aliceStore.find('bob', first.id))!.state,
      ChatState.delivered,
    );
    expect(
      (await aliceStore.find('bob', second.id))!.state,
      ChatState.delivered,
    );
  });

  test('sending to someone who is not a contact is refused', () async {
    final alice = device('alice', contacts: {'bob'});
    await expectLater(
      alice.sendText('eve', 'hello'),
      throwsA(isA<ArgumentError>()),
    );
    expect(net.sent, isEmpty);
  });

  test('empty text is refused before anything is sent', () async {
    final alice = device('alice', contacts: {'bob'});
    await expectLater(
      alice.sendText('bob', '  \u0000  '),
      throwsA(isA<ArgumentError>()),
    );
    expect(net.sent, isEmpty);
  });

  test(
    'a contact with two devices: only the first to answer connects',
    () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      final firstStore = ChatStore(MemorySecretStore());
      final secondStore = ChatStore(MemorySecretStore());
      device('bob', contacts: {'alice'}, store: firstStore);
      device('bob', contacts: {'alice'}, store: secondStore);

      final message = await alice.sendText('bob', 'to both of you');
      await _settle();

      // One connection was made on Bob's side, not two.
      expect(net.rtcs['bob'], hasLength(1));
      // The message landed on exactly one of Bob's devices.
      final onFirst = await firstStore.messages('alice');
      final onSecond = await secondStore.messages('alice');
      expect(onFirst.length + onSecond.length, 1);
      expect((onFirst + onSecond).single.text, 'to both of you');
      expect(
        (await aliceStore.find('bob', message.id))!.state,
        ChatState.delivered,
      );
    },
  );

  test(
    'a stranger opening a chat is declined, and no connection is made',
    () async {
      device('bob', contacts: {'alice'});
      net.deliver(
        'eve',
        'bob',
        'chat.open',
        const {},
        'AAAAAAAAAAAAAAAAAAAAAA',
      );
      await _settle();

      final replies = net.sent.where((s) => s.from == 'bob');
      expect(replies.map((r) => (r.to, r.type)), [('eve', 'chat.decline')]);
      expect(net.rtcs['bob'] ?? const <_FakeRtc>[], isEmpty);
    },
  );

  test('a chat nobody answers fails, and its message is not sent', () async {
    final store = ChatStore(MemorySecretStore());
    final alice = device('alice', contacts: {'bob'}, store: store);
    final events = <ChatManagerEvent>[];
    final sub = alice.events.listen(events.add);

    final message = await alice.sendText('bob', 'anyone there?');
    await _settle();
    now = now.add(const Duration(seconds: 21));
    await alice.tick();
    await _settle();

    expect(events.whereType<ChatOpenFailure>().single.reason, 'no-answer');
    expect((await store.find('bob', message.id))!.state, ChatState.notSent);
    expect((await store.find('bob', message.id))!.reason, 'no-answer');
    await sub.cancel();
  });

  test('when a chat fails, the store already says "not sent" when the screen is told', () async {
    // The chat screen reloads from the store when it hears of the failure. If
    // the store has not written the new state yet, the bubble stays "Sending"
    // and nothing reloads it again.
    final store = ChatStore(_SlowSecrets(const Duration(milliseconds: 50)));
    final alice = device('alice', contacts: {'bob'}, store: store);
    final storedWhenTold = <ChatState?>[];
    late String messageId;
    final sub = alice.events.listen((event) {
      if (event case ChatUpdate(event: MessageNotSent())) {
        storedWhenTold.add(null);
        final index = storedWhenTold.length - 1;
        unawaited(
          store
              .find('bob', messageId)
              .then((m) => storedWhenTold[index] = m?.state),
        );
      }
    });

    final message = await alice.sendText('bob', 'anyone there?');
    messageId = message.id;
    await _settle();
    now = now.add(const Duration(seconds: 21));
    // Another write is still in progress when the chat fails.
    unawaited(
      store.add(
        ChatMessage(
          id: ChatFrames.newId(),
          contactId: 'carol',
          outgoing: true,
          ts: 1,
          text: 'written meanwhile',
          state: ChatState.delivered,
        ),
      ),
    );
    await alice.tick();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(storedWhenTold, [ChatState.notSent]);
    await sub.cancel();
  });

  test(
    'a connection that cannot be set up marks the message not sent',
    () async {
      final store = ChatStore(MemorySecretStore());
      final alice = device(
        'alice',
        contacts: {'bob'},
        failCreate: true,
        store: store,
      );
      device('bob', contacts: {'alice'});

      final message = await alice.sendText('bob', 'lost');
      await _settle();

      expect((await store.find('bob', message.id))!.state, ChatState.notSent);
    },
  );

  test(
    'a connection that never opens times out, and its message is not sent',
    () async {
      final store = ChatStore(MemorySecretStore());
      final alice = device(
        'alice',
        contacts: {'bob'},
        store: store,
        connectTimeout: const Duration(milliseconds: 50),
      );
      device('bob', contacts: {'alice'}, neverOpens: true);

      final message = await alice.sendText('bob', 'stuck');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _settle();

      expect((await store.find('bob', message.id))!.state, ChatState.notSent);
    },
  );

  test(
    'Hide my IP address makes the connection of this device relay-only',
    () async {
      final alice = device('alice', contacts: {'bob'}, hideIp: true);
      device('bob', contacts: {'alice'});
      await alice.sendText('bob', 'hidden');
      await _settle();

      expect(net.rtcs['alice']!.single.relayOnly, isTrue);
      expect(net.rtcs['bob']!.single.relayOnly, isFalse);
    },
  );

  test('connection candidates reach the other side', () async {
    final alice = device('alice', contacts: {'bob'});
    device('bob', contacts: {'alice'});
    await alice.sendText('bob', 'with candidates');
    await _settle();

    expect(net.rtcs['bob']!.single.addedCandidates, isNotEmpty);
  });

  test('closing a chat ends it on both sides', () async {
    final alice = device('alice', contacts: {'bob'});
    final bob = device('bob', contacts: {'alice'});
    final bobEvents = <ChatManagerEvent>[];
    final sub = bob.events.listen(bobEvents.add);

    await alice.sendText('bob', 'hello');
    await _settle();
    await alice.close('bob');
    await _settle();

    expect(alice.isActive('bob'), isFalse);
    expect(bob.isActive('alice'), isFalse);
    final ended = bobEvents
        .whereType<ChatUpdate>()
        .map((u) => u.event)
        .whereType<SessionEnded>();
    expect(ended, isNotEmpty);
    await sub.cancel();
  });

  test('when another device wins the answer, messages waiting for this device fail', () async {
    final store = ChatStore(MemorySecretStore());
    final sent =
        <
          ({String to, String type, Map<String, Object?> body, String? callId})
        >[];
    final manager = ChatManager(
      myId: 'zzz',
      store: store,
      isContact: {'aaa'}.contains,
      send: (to, type, body, callId) =>
          sent.add((to: to, type: type, body: body, callId: callId)),
      iceServers: () async => const [],
      hideIp: () => false,
      createRtc: ({required iceServers, required relayOnly}) async =>
          throw StateError('no connection expected'),
      clock: () => now,
    );
    managers.add(manager);
    final events = <ChatManagerEvent>[];
    final sub = manager.events.listen(events.add);

    // This device opens a chat, and the contact opens one at the same moment.
    final message = await manager.sendText('aaa', 'queued');
    final ours = sent.single.callId!;
    final theirs = ChatFrames.newId();
    manager.handle(
      from: 'aaa',
      type: 'chat.open',
      body: const {},
      callId: theirs,
    );
    await _settle();
    // Another device of the contact answered first and won.
    manager.handle(
      from: 'aaa',
      type: 'chat.taken',
      body: {'tag': ChatFrames.newId()},
      callId: theirs,
    );
    await _settle();

    expect(ours, isNot(theirs));
    expect((await store.find('aaa', message.id))!.state, ChatState.notSent);
    expect((await store.find('aaa', message.id))!.reason, 'dropped');
    expect(events.whereType<ChatOpenFailure>().single.reason, 'dropped');
    await sub.cancel();
  });

  test('Hide my IP address with no relay server fails at once, and never connects directly', () async {
    final store = ChatStore(MemorySecretStore());
    final alice = device(
      'alice',
      contacts: {'bob'},
      hideIp: true,
      store: store,
      servers: [
        {'urls': 'stun:stun.test'},
      ],
    );
    device('bob', contacts: {'alice'});

    final message = await alice.sendText('bob', 'hidden');
    await _settle();

    expect((await store.find('bob', message.id))!.state, ChatState.notSent);
    expect(net.rtcs['alice'] ?? const <_FakeRtc>[], isEmpty);
    expect(net.sent.where((s) => s.type == 'chat.offer'), isEmpty);
  });

  test('a message that was not sent goes out when retried, once', () async {
    final aliceStore = ChatStore(MemorySecretStore());
    final alice = device('alice', contacts: {'bob'}, store: aliceStore);
    final message = await alice.sendText('bob', 'retry me');
    await _settle();
    // Bob is not online yet: the chat fails.
    now = now.add(const Duration(seconds: 21));
    await alice.tick();
    await _settle();
    expect(
      (await aliceStore.find('bob', message.id))!.state,
      ChatState.notSent,
    );

    // Bob comes online, and the same message is sent again.
    final bobStore = ChatStore(MemorySecretStore());
    device('bob', contacts: {'alice'}, store: bobStore);
    await alice.retry('bob', message.id);
    await _settle();

    expect(
      (await aliceStore.find('bob', message.id))!.state,
      ChatState.delivered,
    );
    final received = await bobStore.messages('alice');
    expect(received.map((m) => m.text), ['retry me']);
    expect(await aliceStore.messages('bob'), hasLength(1));
  });

  test('the chat on screen is known, and only that one', () async {
    final alice = device('alice', contacts: {'bob', 'carol'});
    expect(alice.isViewing('bob'), isFalse);

    alice.viewing('bob');
    expect(alice.isViewing('bob'), isTrue);
    expect(alice.isViewing('carol'), isFalse);

    alice.viewing(null);
    expect(alice.isViewing('bob'), isFalse);
    await alice.dispose();
  });

  test('queued messages can be unqueued or automatically flushed when peer is online', () async {
    final aliceStore = ChatStore(MemorySecretStore());
    final alice = device('alice', contacts: {'bob'}, store: aliceStore);

    final message = await alice.sendText('bob', 'wait for me');
    await _settle();
    now = now.add(const Duration(seconds: 21));
    await alice.tick();
    await _settle();

    expect(
      (await aliceStore.find('bob', message.id))!.state,
      ChatState.notSent,
    );

    // Queue the message
    await alice.queue('bob', message.id);
    expect((await aliceStore.find('bob', message.id))!.state, ChatState.queued);

    // Unqueue cancels it
    await alice.unqueue('bob', message.id);
    expect(
      (await aliceStore.find('bob', message.id))!.state,
      ChatState.notSent,
    );

    // Queue again
    await alice.queue('bob', message.id);
    expect((await aliceStore.find('bob', message.id))!.state, ChatState.queued);

    // Bob comes online, flushOutbox delivers it
    final bobStore = ChatStore(MemorySecretStore());
    device('bob', contacts: {'alice'}, store: bobStore);

    await alice.flushOutbox('bob');
    await _settle();

    expect(
      (await aliceStore.find('bob', message.id))!.state,
      ChatState.delivered,
    );
    expect((await bobStore.messages('alice')).single.text, 'wait for me');
  });

  test(
    'sendTyping and sendReadReceipts are dispatched across active sessions',
    () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      final bob = device('bob', contacts: {'alice'}, store: bobStore);

      final bobEvents = <ChatManagerEvent>[];
      bob.events.listen(bobEvents.add);
      final aliceEvents = <ChatManagerEvent>[];
      alice.events.listen(aliceEvents.add);

      final msg = await alice.sendText('bob', 'Hello Bob');
      await _settle();

      expect((await bobStore.messages('alice')).single.text, 'Hello Bob');

      // Alice types
      alice.sendTyping('bob', true);
      await _settle();

      final typingEvent = bobEvents
          .whereType<ChatUpdate>()
          .where((e) => e.contact == 'alice' && e.event is PeerTyping)
          .lastOrNull;
      expect(typingEvent, isNotNull);
      expect((typingEvent!.event as PeerTyping).typing, isTrue);

      // Bob reads the message and sends read receipt
      bob.sendReadReceipts('alice', [msg.id]);
      await _settle();

      expect((await aliceStore.find('bob', msg.id))?.state, ChatState.read);
      final readEvent = aliceEvents
          .whereType<ChatUpdate>()
          .where((e) => e.contact == 'bob' && e.event is MessagesRead)
          .lastOrNull;
      expect(readEvent, isNotNull);
      expect((readEvent!.event as MessagesRead).ids, [msg.id]);
    },
  );
}
