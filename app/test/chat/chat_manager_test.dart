import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_rtc.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/image_metadata.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity_store.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

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
    // Not awaited: a controller nobody listens to never completes its close,
    // and that must not hang the caller (chat_rtc.dart does the same).
    if (!_frames.isClosed) unawaited(_frames.close());
    if (!_binaryFrames.isClosed) unawaited(_binaryFrames.close());
    if (!_candidates.isClosed) unawaited(_candidates.close());
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
  int get bufferedAmount => 0;

  @override
  Future<int> bufferedAmountNow() async => 0;

  @override
  Future<void> close() async {
    if (!owner._frames.isClosed) unawaited(owner._frames.close());
    if (!owner._binaryFrames.isClosed) unawaited(owner._binaryFrames.close());
  }
}

/// Delivers envelopes between devices, one microtask later, as a relay does.
class _Network {
  final managers = <String, List<ChatManager>>{};
  final registry = <String, _FakeRtc>{};
  final rtcs = <String, List<_FakeRtc>>{};
  final sent = <({String from, String to, String type})>[];

  /// Whether texts sent through the relay arrive. Tests of a failing direct
  /// chat turn this off, so the message really cannot get through.
  bool relayText = true;

  void deliver(
    String from,
    String to,
    String type,
    Map<String, Object?> body,
    String? callId,
  ) {
    sent.add((from: from, to: to, type: type));
    if (!relayText && type == ChatManager.relayText) return;
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

  @override
  Future<void> writeAll(
    Map<String, String> values, {
    Iterable<String> deleted = const [],
  }) async {
    await Future<void>.delayed(delay);
    await _inner.writeAll(values, deleted: deleted);
  }
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
    bool Function()? readReceiptsEnabled,
    bool Function()? autoDownloadFiles,
    int maxFileBytes = maxFileSizeNative,
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
      readReceiptsEnabled: readReceiptsEnabled ?? () => true,
      autoDownloadFiles: autoDownloadFiles ?? () => false,
      maxFileBytes: maxFileBytes,
      offerReadyWait: Duration.zero,
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
      // The direct chat reached one device; the relay copy reached both, and
      // neither stored it twice.
      final onFirst = await firstStore.messages('alice');
      final onSecond = await secondStore.messages('alice');
      expect(onFirst.map((m) => m.text), ['to both of you']);
      expect(onSecond.map((m) => m.text), ['to both of you']);
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
      net.relayText = false;
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
      net.relayText = false;
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
    net.relayText = false;
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
    final ours = sent.firstWhere((s) => s.type == 'chat.open').callId!;
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
    net.relayText = false;
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

  test('with read receipts off, a chat opening sends no receipt for messages read on this device', () async {
    final aliceStore = ChatStore(MemorySecretStore());
    final bobStore = ChatStore(MemorySecretStore());
    final alice = device('alice', contacts: {'bob'}, store: aliceStore);
    device(
      'bob',
      contacts: {'alice'},
      store: bobStore,
      readReceiptsEnabled: () => false,
    );

    final first = await alice.sendText('bob', 'read this');
    await _settle();
    // Bob reads it on this device. With receipts off, nothing is sent.
    await bobStore.markAsRead('alice');
    await alice.close('bob');
    await _settle();

    // The next chat opens between them, from Alice's side.
    await alice.sendText('bob', 'next');
    await _settle();

    expect(
      (await aliceStore.find('bob', first.id))!.state,
      isNot(ChatState.read),
    );
    expect(
      (await aliceStore.find('bob', first.id))!.state,
      ChatState.delivered,
    );
  });

  test('with read receipts on, a chat opening sends the receipt for messages read on this device', () async {
    final aliceStore = ChatStore(MemorySecretStore());
    final bobStore = ChatStore(MemorySecretStore());
    final alice = device('alice', contacts: {'bob'}, store: aliceStore);
    device('bob', contacts: {'alice'}, store: bobStore);

    final first = await alice.sendText('bob', 'read this');
    await _settle();
    await bobStore.markAsRead('alice');
    await alice.close('bob');
    await _settle();

    await alice.sendText('bob', 'next');
    await _settle();

    expect((await aliceStore.find('bob', first.id))!.state, ChatState.read);
  });

  group('texts through the relay', () {
    test('a text reaches a device whose direct chat cannot connect', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      // Bob's app is in the background: its direct chat never opens.
      device('bob', contacts: {'alice'}, store: bobStore, neverOpens: true);
      final bobEvents = <ChatManagerEvent>[];
      final sub = net.managers['bob']!.single.events.listen(bobEvents.add);

      final message = await alice.sendText('bob', 'are you free later?');
      await _settle();

      final got = await bobStore.messages('alice');
      expect(got.map((m) => m.text), ['are you free later?']);
      expect(got.single.outgoing, isFalse);
      expect(got.single.arrivedAt, now.millisecondsSinceEpoch);
      expect(
        bobEvents.whereType<ChatUpdate>().map((u) => u.event),
        contains(isA<MessageReceived>()),
      );
      expect(
        (await aliceStore.find('bob', message.id))!.state,
        ChatState.delivered,
      );
      await sub.cancel();
    });

    test(
      'a delivered text stays delivered when the direct chat later fails',
      () async {
        final aliceStore = ChatStore(MemorySecretStore());
        final alice = device(
          'alice',
          contacts: {'bob'},
          store: aliceStore,
          neverOpens: true,
        );
        device('bob', contacts: {'alice'}, neverOpens: true);

        final message = await alice.sendText('bob', 'hello');
        await _settle();
        // The direct chat times out after the relay copy was acknowledged.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _settle();

        expect(
          (await aliceStore.find('bob', message.id))!.state,
          ChatState.delivered,
        );
      },
    );

    test('a relay ack records when it arrived, the first time only', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      // Nobody is set up for Bob here, so nothing acknowledges the text yet.
      final message = await alice.sendText('bob', 'hello');
      await _settle();

      now = now.add(const Duration(minutes: 5));
      final ackedAt = now.millisecondsSinceEpoch;
      alice.handle(
        from: 'bob',
        type: ChatManager.relayTextAck,
        body: {'id': message.id},
        callId: null,
      );
      await _settle();
      var stored = (await aliceStore.find('bob', message.id))!;
      expect(stored.state, ChatState.delivered);
      expect(stored.deliveredAt, ackedAt);
      expect(stored.readAt, isNull);

      now = now.add(const Duration(minutes: 5));
      alice.handle(
        from: 'bob',
        type: ChatManager.relayTextAck,
        body: {'id': message.id},
        callId: null,
      );
      await _settle();
      stored = (await aliceStore.find('bob', message.id))!;
      expect(stored.deliveredAt, ackedAt);
    });

    test(
      'a text that arrives twice is stored once and acknowledged each time',
      () async {
        final bobStore = ChatStore(MemorySecretStore());
        device('bob', contacts: {'alice'}, store: bobStore);
        final body = {'id': 'AAAAAAAAAAAAAAAAAAAAAA', 'ts': 1, 'text': 'once'};
        net.deliver('alice', 'bob', ChatManager.relayText, body, null);
        net.deliver('alice', 'bob', ChatManager.relayText, body, null);
        await _settle();

        expect((await bobStore.messages('alice')).map((m) => m.text), ['once']);
        expect(
          net.sent.where(
            (s) => s.from == 'bob' && s.type == ChatManager.relayTextAck,
          ),
          hasLength(2),
        );
      },
    );

    test(
      'a text from someone who is not a contact is dropped unanswered',
      () async {
        final bobStore = ChatStore(MemorySecretStore());
        device('bob', contacts: {'alice'}, store: bobStore);
        net.deliver('eve', 'bob', ChatManager.relayText, {
          'id': 'AAAAAAAAAAAAAAAAAAAAAA',
          'ts': 1,
          'text': 'hi',
        }, null);
        await _settle();

        expect(await bobStore.messages('eve'), isEmpty);
        expect(net.sent.where((s) => s.from == 'bob'), isEmpty);
      },
    );

    test('malformed relay texts are dropped', () async {
      final bobStore = ChatStore(MemorySecretStore());
      device('bob', contacts: {'alice'}, store: bobStore);
      for (final body in <Map<String, Object?>>[
        {'id': 'short', 'ts': 1, 'text': 'x'},
        {'id': 'AAAAAAAAAAAAAAAAAAAAAA', 'ts': 'soon', 'text': 'x'},
        {'id': 'AAAAAAAAAAAAAAAAAAAAAA', 'ts': 1, 'text': '   '},
        {'id': 'AAAAAAAAAAAAAAAAAAAAAA', 'ts': 1, 'text': 'x' * 5000},
      ]) {
        net.deliver('alice', 'bob', ChatManager.relayText, body, null);
      }
      await _settle();

      expect(await bobStore.messages('alice'), isEmpty);
    });

    test(
      'a text whose relay copy was lost goes through on the next check',
      () async {
        final aliceStore = ChatStore(MemorySecretStore());
        final bobStore = ChatStore(MemorySecretStore());
        final alice = device(
          'alice',
          contacts: {'bob'},
          store: aliceStore,
          neverOpens: true,
        );
        device('bob', contacts: {'alice'}, store: bobStore, neverOpens: true);

        // The first copy is lost (the relay handed it to a dead connection).
        net.relayText = false;
        final message = await alice.sendText('bob', 'still there?');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _settle();
        expect(await bobStore.messages('alice'), isEmpty);
        expect(
          (await aliceStore.find('bob', message.id))!.state,
          ChatState.notSent,
        );

        // The next check sends it again, and this time it arrives.
        net.relayText = true;
        await alice.tick();
        await _settle();

        expect((await bobStore.messages('alice')).map((m) => m.text), [
          'still there?',
        ]);
        expect(
          (await aliceStore.find('bob', message.id))!.state,
          ChatState.delivered,
        );
      },
    );

    test('old and cancelled texts are not sent again', () async {
      final store = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: store);
      final old = now
          .subtract(ChatManager.relayRetryWindow + const Duration(minutes: 1))
          .millisecondsSinceEpoch;
      await store.add(
        ChatMessage(
          id: 'AAAAAAAAAAAAAAAAAAAAAA',
          contactId: 'bob',
          outgoing: true,
          ts: old,
          text: 'too old',
          state: ChatState.notSent,
          reason: 'no-answer',
        ),
      );
      await store.add(
        ChatMessage(
          id: 'BBBBBBBBBBBBBBBBBBBBBA',
          contactId: 'bob',
          outgoing: true,
          ts: now.millisecondsSinceEpoch,
          text: 'cancelled',
          state: ChatState.notSent,
          reason: 'cancelled',
        ),
      );
      await alice.tick();
      await _settle();

      expect(net.sent.where((s) => s.type == ChatManager.relayText), isEmpty);
    });

    test('a queued file is never sent through the relay', () async {
      final store = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: store);
      await store.add(
        const ChatMessage(
          id: 'AAAAAAAAAAAAAAAAAAAAAA',
          contactId: 'bob',
          outgoing: true,
          ts: 1,
          text: '',
          state: ChatState.queued,
          fileName: 'notes.txt',
          fileSize: 3,
        ),
      );
      await alice.flushOutbox('bob');
      await _settle();

      expect(net.sent.where((s) => s.type == ChatManager.relayText), isEmpty);
    });
  });

  group('files', () {
    /// Makes Alice's queued file go to Bob, who comes online only now: the
    /// chat Alice opened while Bob was away times out, and the next check
    /// opens one with Bob.
    Future<void> bobComesOnline(ChatManager alice, ChatStore bobStore) async {
      device('bob', contacts: {'alice'}, store: bobStore);
      now = now.add(const Duration(seconds: 21));
      await alice.tick();
      await _settle();
    }

    test('a queued image has its metadata removed, like a live one', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      final queued = await alice.offerFile(
        contact: 'bob',
        name: 'photo.jpg',
        bytes: _jpegWithGps(),
        mime: 'image/jpeg',
      );
      expect(queued.state, ChatState.queued);
      final kept = await aliceStore.readFile(queued);
      expect(kept, ImageMetadata.clean(_jpegWithGps(), 'image/jpeg'));
      expect(String.fromCharCodes(kept).contains('GPSLatitude'), isFalse);
    });

    test('a queued image that cannot be cleaned is refused, with the live '
        "path's error, and nothing is kept", () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      await expectLater(
        alice.offerFile(
          contact: 'bob',
          name: 'photo.heic',
          bytes: Uint8List.fromList([0, 0, 0, 0x18, ...'ftypheic'.codeUnits]),
          mime: 'image/heic',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Image type not supported for sharing',
          ),
        ),
      );
      await expectLater(
        alice.offerFile(
          contact: 'bob',
          name: 'broken.jpg',
          bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x00]),
          mime: 'image/jpeg',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Image could not be read',
          ),
        ),
      );
      await expectLater(
        alice.offerFile(
          contact: 'bob',
          name: 'run.exe',
          bytes: Uint8List.fromList([1, 2, 3]),
          mime: 'application/octet-stream',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await aliceStore.messages('bob'), isEmpty);
    });

    test('the size limit given to the manager applies to sending', () async {
      final alice = device('alice', contacts: {'bob'}, maxFileBytes: 10);
      await expectLater(
        alice.offerFile(
          contact: 'bob',
          name: 'big.txt',
          bytes: Uint8List(11),
          mime: 'text/plain',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'File exceeds max size limit',
          ),
        ),
      );
    });

    test('a queued file in the browser is offered once when the contact is '
        'online, and is never sent as a text', () async {
      // Neither store keeps files on disk, as in the browser.
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      final bytes = Uint8List.fromList(List.generate(40000, (i) => i % 251));

      final queued = await alice.offerFile(
        contact: 'bob',
        name: 'notes.txt',
        bytes: bytes,
        mime: 'text/plain',
      );
      await _settle();
      expect(queued.filePath, 'web:${queued.id}');
      expect(
        (await aliceStore.find('bob', queued.id))!.state,
        ChatState.queued,
      );

      await bobComesOnline(alice, bobStore);
      // Flushed again while the chat is ready: still offered once.
      await alice.flushOutbox('bob');
      await _settle();

      final atBob = await bobStore.messages('alice');
      expect(atBob, hasLength(1));
      expect(atBob.single.id, queued.id);
      expect(atBob.single.isAttachment, isTrue);
      // Downloads only when accepted (the setting is off).
      expect(atBob.single.fileStatus, 'offered');
      expect(
        (await aliceStore.find('bob', queued.id))!.state,
        ChatState.sending,
      );

      await net.managers['bob']!.single.acceptFile('alice', queued.id);
      await _settle();
      final done = await bobStore.find('alice', queued.id);
      expect(done!.fileStatus, 'completed');
      expect(await bobStore.readFile(done), bytes);
      expect(
        (await aliceStore.find('bob', queued.id))!.fileStatus,
        'completed',
      );

      // The next chat does not offer it again.
      await alice.close('bob');
      await _settle();
      await alice.sendText('bob', 'again');
      await _settle();
      expect(
        (await bobStore.messages('alice')).where((m) => m.isAttachment),
        hasLength(1),
      );
    });

    test('a queued file stays queued across a chat that never connects, and '
        'across a restart', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      final queued = await alice.offerFile(
        contact: 'bob',
        name: 'notes.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
        mime: 'text/plain',
      );
      now = now.add(const Duration(seconds: 21));
      await alice.tick();
      await _settle();
      await alice.recoverInterrupted();

      final after = await aliceStore.find('bob', queued.id);
      expect(after!.state, ChatState.queued);
      expect(after.fileStatus, 'offered');
    });

    test('files from a contact download only with the setting on', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      var autoOn = false;
      device(
        'bob',
        contacts: {'alice'},
        store: bobStore,
        autoDownloadFiles: () => autoOn,
      );
      await alice.sendText('bob', 'hi');
      await _settle();

      final first = await alice.offerFile(
        contact: 'bob',
        name: 'a.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
        mime: 'text/plain',
      );
      await _settle();
      expect((await bobStore.find('alice', first.id))!.fileStatus, 'offered');

      autoOn = true;
      final second = await alice.offerFile(
        contact: 'bob',
        name: 'b.txt',
        bytes: Uint8List.fromList([4, 5, 6]),
        mime: 'text/plain',
      );
      await _settle();
      expect(
        (await bobStore.find('alice', second.id))!.fileStatus,
        'completed',
      );
      expect((await bobStore.find('alice', first.id))!.fileStatus, 'offered');
    });
  });

  group('replies, forwards, reactions, edits and deletes', () {
    test('a reply carries its quote, and a forwarded text its mark', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      device('bob', contacts: {'alice'}, store: bobStore);

      final question = await alice.sendText('bob', 'Are you free?');
      await _settle();
      final answer = await alice.sendText(
        'bob',
        'Yes',
        replyToId: question.id,
        forwarded: true,
      );
      await _settle();

      final received = (await bobStore.find('alice', answer.id))!;
      expect(received.replyTo, (id: question.id, text: 'Are you free?'));
      expect(received.forwarded, isTrue);
      expect(
        (await aliceStore.find('bob', answer.id))!.state,
        ChatState.delivered,
      );
    });

    test('a reply to a message that is not in the chat is refused', () async {
      final alice = device('alice', contacts: {'bob'});
      await expectLater(
        alice.sendText('bob', 'Yes', replyToId: _id(77)),
        throwsA(isA<ArgumentError>()),
      );
      expect(net.sent, isEmpty);
    });

    test(
      'a reply or a forwarded text is never sent through the relay',
      () async {
        final alice = device(
          'alice',
          contacts: {'bob'},
          store: ChatStore(MemorySecretStore()),
        );
        // Bob's device runs, but its connection never opens: only the relay
        // could carry a text.
        device('bob', contacts: {'alice'}, neverOpens: true);
        final question = await alice.sendText('bob', 'Are you free?');
        await _settle();
        int relayed() =>
            net.sent.where((s) => s.type == ChatManager.relayText).length;
        expect(relayed(), 1, reason: 'a plain text goes through the relay');

        await alice.sendText('bob', 'Yes', replyToId: question.id);
        await alice.sendText('bob', 'Again', forwarded: true);
        await _settle();
        expect(relayed(), 1);
      },
    );

    test('a reaction made while the contact is offline is kept and sent when a chat opens', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      // Bob's message, as each device keeps it.
      await bobStore.add(
        ChatMessage(
          id: _id(1),
          contactId: 'alice',
          outgoing: true,
          ts: now.millisecondsSinceEpoch,
          text: 'Lunch?',
          state: ChatState.read,
        ),
      );
      await aliceStore.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: false,
          ts: now.millisecondsSinceEpoch,
          text: 'Lunch?',
          state: ChatState.received,
          read: false,
        ),
      );
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      expect(await alice.react('bob', _id(1), '\u{1F44D}'), isTrue);
      expect((await aliceStore.find('bob', _id(1)))!.reactions, {
        'me': '\u{1F44D}',
      });
      expect(await aliceStore.pendingControls('bob'), hasLength(1));
      expect(net.sent, isEmpty);

      device('bob', contacts: {'alice'}, store: bobStore);
      await alice.sendText('bob', 'Ping');
      await _settle();

      expect((await bobStore.find('alice', _id(1)))!.reactions, {
        'peer': '\u{1F44D}',
      });
      expect(await aliceStore.pendingControls('bob'), isEmpty);
    });

    test(
      'a reaction on a message the contact has not stored yet waits for it',
      () async {
        final aliceStore = ChatStore(MemorySecretStore());
        final bobStore = ChatStore(MemorySecretStore());
        final alice = device('alice', contacts: {'bob'}, store: aliceStore);
        // Bob is offline, so the text is not stored there.
        final text = await alice.sendText('bob', 'Are you there?');
        await _settle();
        now = now.add(const Duration(seconds: 21));
        await alice.tick();
        await _settle();
        expect(
          (await aliceStore.find('bob', text.id))!.state,
          ChatState.notSent,
        );

        expect(await alice.react('bob', text.id, '\u{1F44D}'), isTrue);
        expect(await aliceStore.pendingControls('bob'), hasLength(1));

        // Bob comes online. Retrying sends the text first, then the reaction.
        device('bob', contacts: {'alice'}, store: bobStore);
        await alice.retry('bob', text.id);
        await _settle();

        final received = (await bobStore.find('alice', text.id))!;
        expect(received.text, 'Are you there?');
        expect(received.reactions, {'peer': '\u{1F44D}'});
        expect(await aliceStore.pendingControls('bob'), isEmpty);
      },
    );

    test('a reaction that is not an emoji is refused, and one on an unknown message is not kept', () async {
      final alice = device('alice', contacts: {'bob'});
      await expectLater(
        alice.react('bob', _id(1), 'a\u0007'),
        throwsA(isA<ArgumentError>()),
      );
      expect(await alice.react('bob', _id(1), '\u{1F44D}'), isFalse);
      expect(await alice.react('bob', _id(1), ''), isFalse);
    });

    test('an edit shows at once and reaches the contact; after 15 minutes it is refused', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      final bob = device('bob', contacts: {'alice'}, store: bobStore);
      final first = await alice.sendText('bob', 'first try');
      final theirs = await bob.sendText('alice', 'their text');
      await _settle();

      now = now.add(const Duration(minutes: 10));
      expect(await alice.edit('bob', first.id, 'fixed'), isTrue);
      final editedAt = now.millisecondsSinceEpoch;
      expect((await aliceStore.find('bob', first.id))!.text, 'fixed');
      await _settle();
      final received = (await bobStore.find('alice', first.id))!;
      expect(received.text, 'fixed');
      expect(received.editedAt, editedAt);

      now = now.add(const Duration(minutes: 6));
      expect(await alice.edit('bob', first.id, 'too late'), isFalse);
      expect((await aliceStore.find('bob', first.id))!.text, 'fixed');
      // Only your own text messages can be edited.
      expect(await alice.edit('bob', theirs.id, 'not mine'), isFalse);
    });

    test('a delete for everyone applies here at once and reaches the contact, within an hour', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      device('bob', contacts: {'alice'}, store: bobStore);
      final secret = await alice.sendText('bob', 'secret');
      await _settle();

      expect(await alice.deleteForEveryone('bob', secret.id), isTrue);
      final here = (await aliceStore.find('bob', secret.id))!;
      expect(here.deletedForAll, isTrue);
      expect(here.text, isEmpty);
      await _settle();
      final there = (await bobStore.find('alice', secret.id))!;
      expect(there.deletedForAll, isTrue);
      expect(there.text, isEmpty);

      final late = await alice.sendText('bob', 'later');
      await _settle();
      now = now.add(const Duration(hours: 1, minutes: 1));
      expect(await alice.deleteForEveryone('bob', late.id), isFalse);
      expect((await aliceStore.find('bob', late.id))!.text, 'later');
    });

    test('a delete made while the contact is offline reaches it when a chat opens within the hour', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      // Delivered earlier: both devices have the message.
      final message = ChatMessage(
        id: _id(1),
        contactId: 'bob',
        outgoing: true,
        ts: now.millisecondsSinceEpoch,
        text: 'Lunch?',
        state: ChatState.delivered,
      );
      await aliceStore.add(message);
      await bobStore.add(
        message.copyWith(
          contactId: 'alice',
          outgoing: false,
          read: false,
          state: ChatState.received,
        ),
      );
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      expect(await alice.deleteForEveryone('bob', _id(1)), isTrue);
      expect(await aliceStore.pendingControls('bob'), hasLength(1));

      now = now.add(const Duration(minutes: 30));
      device('bob', contacts: {'alice'}, store: bobStore);
      await alice.sendText('bob', 'hi');
      await _settle();

      expect(await aliceStore.pendingControls('bob'), isEmpty);
      expect((await bobStore.find('alice', _id(1)))!.deletedForAll, isTrue);
    });

    test('a delete made while the contact is offline still reaches it when a chat opens, after the hour', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final message = ChatMessage(
        id: _id(1),
        contactId: 'bob',
        outgoing: true,
        ts: now.millisecondsSinceEpoch,
        text: 'Lunch?',
        state: ChatState.delivered,
      );
      await aliceStore.add(message);
      await bobStore.add(
        message.copyWith(
          contactId: 'alice',
          outgoing: false,
          read: false,
          state: ChatState.received,
        ),
      );
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      expect(await alice.deleteForEveryone('bob', _id(1)), isTrue);
      expect(await aliceStore.pendingControls('bob'), hasLength(1));

      // Two hours later the delete is still sent: its window was checked when
      // it was made, and the other side applies it on its own clock.
      now = now.add(const Duration(hours: 2));
      device('bob', contacts: {'alice'}, store: bobStore);
      await alice.sendText('bob', 'hi');
      await _settle();

      expect(await aliceStore.pendingControls('bob'), isEmpty);
      final gone = (await bobStore.find('alice', _id(1)))!;
      expect(gone.deletedForAll, isTrue);
      expect(gone.text, isEmpty);
    });

    test('an edit made while the contact is offline is applied when a chat opens, even after its window', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final message = ChatMessage(
        id: _id(1),
        contactId: 'bob',
        outgoing: true,
        ts: now.millisecondsSinceEpoch,
        text: 'Lunch?',
        state: ChatState.delivered,
      );
      await aliceStore.add(message);
      await bobStore.add(
        message.copyWith(
          contactId: 'alice',
          outgoing: false,
          read: false,
          state: ChatState.received,
        ),
      );
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      // Ten minutes after the message, inside its window; Bob is offline.
      now = now.add(const Duration(minutes: 10));
      final editedAt = now.millisecondsSinceEpoch;
      expect(await alice.edit('bob', _id(1), 'Lunch at one?'), isTrue);
      expect(await aliceStore.pendingControls('bob'), hasLength(1));

      // Thirty minutes later, when Bob's chat opens, the window of the message
      // has closed. The edit was made in time, so Bob still gets it.
      now = now.add(const Duration(minutes: 30));
      device('bob', contacts: {'alice'}, store: bobStore);
      await alice.sendText('bob', 'hi');
      await _settle();

      expect(await aliceStore.pendingControls('bob'), isEmpty);
      final edited = (await bobStore.find('alice', _id(1)))!;
      expect(edited.text, 'Lunch at one?');
      expect(edited.editedAt, editedAt);
    });

    test('a delete made while the contact is offline is dropped once it is more than seven days old', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final message = ChatMessage(
        id: _id(1),
        contactId: 'bob',
        outgoing: true,
        ts: now.millisecondsSinceEpoch,
        text: 'Lunch?',
        state: ChatState.delivered,
      );
      await aliceStore.add(message);
      await bobStore.add(
        message.copyWith(
          contactId: 'alice',
          outgoing: false,
          read: false,
          state: ChatState.received,
        ),
      );
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);

      expect(await alice.deleteForEveryone('bob', _id(1)), isTrue);
      expect(await aliceStore.pendingControls('bob'), hasLength(1));

      // Eight days later the other side would refuse the delete, so it is
      // dropped, not sent.
      now = now.add(const Duration(days: 8));
      device('bob', contacts: {'alice'}, store: bobStore);
      await alice.sendText('bob', 'hi');
      await _settle();

      expect(await aliceStore.pendingControls('bob'), isEmpty);
      final kept = (await bobStore.find('alice', _id(1)))!;
      expect(kept.deletedForAll, isFalse);
      expect(kept.text, 'Lunch?');
    });

    test('a queued message deleted for everyone is never sent; its delete goes with the next chat, and a peer that lacks the message ignores it', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      // Bob has no device yet, so the text cannot go and is queued.
      final secret = await alice.sendText('bob', 'top secret');
      await _settle();
      now = now.add(const Duration(seconds: 21));
      await alice.tick();
      await _settle();
      await alice.queue('bob', secret.id);
      expect(
        (await aliceStore.find('bob', secret.id))!.state,
        ChatState.queued,
      );

      expect(await alice.deleteForEveryone('bob', secret.id), isTrue);
      final gone = (await aliceStore.find('bob', secret.id))!;
      expect(gone.deletedForAll, isTrue);
      expect(gone.text, isEmpty);
      // The delete waits with the other controls. The queue no longer holds
      // the text, so flushing the outbox has nothing to send.
      expect(await aliceStore.pendingControls('bob'), hasLength(1));

      // Bob comes online. The next chat carries the delete, and Bob has no
      // such message, so he ignores it. The text never reaches him.
      final bobStore = ChatStore(MemorySecretStore());
      device('bob', contacts: {'alice'}, store: bobStore);
      await alice.sendText('bob', 'hello');
      await _settle();

      expect(await aliceStore.pendingControls('bob'), isEmpty);
      expect(await bobStore.find('alice', secret.id), isNull);
      expect((await bobStore.messages('alice')).map((m) => m.text), ['hello']);
    });

    test('a delete for everyone takes the text out of the replies to it, on both devices', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      device('bob', contacts: {'alice'}, store: bobStore);

      final quoted = await alice.sendText('bob', 'the door code is 4471');
      await _settle();
      final reply = await alice.sendText('bob', 'got it', replyToId: quoted.id);
      await _settle();
      expect((await bobStore.find('alice', reply.id))!.replyTo, (
        id: quoted.id,
        text: 'the door code is 4471',
      ));

      expect(await alice.deleteForEveryone('bob', quoted.id), isTrue);
      await _settle();

      for (final (store, contact) in [
        (aliceStore, 'bob'),
        (bobStore, 'alice'),
      ]) {
        final deleted = (await store.find(contact, quoted.id))!;
        expect(deleted.deletedForAll, isTrue);
        expect(deleted.text, isEmpty);
        expect(deleted.replyTo, isNull);
        final quote = (await store.find(contact, reply.id))!;
        expect(quote.text, 'got it');
        expect(quote.replyTo, (id: quoted.id, text: ''));
      }
    });

    test('an edit gives the replies to the edited message the new text, on both devices', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final bobStore = ChatStore(MemorySecretStore());
      final alice = device('alice', contacts: {'bob'}, store: aliceStore);
      device('bob', contacts: {'alice'}, store: bobStore);

      final quoted = await alice.sendText('bob', 'the door code is 4471');
      await _settle();
      final reply = await alice.sendText('bob', 'got it', replyToId: quoted.id);
      await _settle();

      expect(
        await alice.edit('bob', quoted.id, 'the door code is 4472'),
        isTrue,
      );
      await _settle();

      for (final (store, contact) in [
        (aliceStore, 'bob'),
        (bobStore, 'alice'),
      ]) {
        final edited = (await store.find(contact, quoted.id))!;
        expect(edited.text, 'the door code is 4472');
        final quote = (await store.find(contact, reply.id))!;
        expect(quote.text, 'got it');
        expect(quote.replyTo, (id: quoted.id, text: 'the door code is 4472'));
      }
    });

    test('a text that came through the relay keeps the arrival time when its own time is far ahead', () async {
      final bobStore = ChatStore(MemorySecretStore());
      final bob = device('bob', contacts: {'alice'}, store: bobStore);

      bob.handle(
        from: 'alice',
        type: ChatManager.relayText,
        body: {
          'id': _id(1),
          'ts':
              now.millisecondsSinceEpoch +
              const Duration(hours: 1).inMilliseconds,
          'text': 'hello',
        },
        callId: null,
      );
      await _settle();

      final received = (await bobStore.find('alice', _id(1)))!;
      expect(received.text, 'hello');
      expect(received.ts, now.millisecondsSinceEpoch);
      expect(received.arrivedAt, now.millisecondsSinceEpoch);
    });

    test(
      'a message deleted before the contact had it is never sent with its text',
      () async {
        final aliceStore = ChatStore(MemorySecretStore());
        final bobStore = ChatStore(MemorySecretStore());
        final alice = device('alice', contacts: {'bob'}, store: aliceStore);
        // Bob is offline: the text is never stored there.
        final secret = await alice.sendText('bob', 'secret');
        await _settle();
        now = now.add(const Duration(seconds: 21));
        await alice.tick();
        await _settle();
        expect(
          (await aliceStore.find('bob', secret.id))!.state,
          ChatState.notSent,
        );

        expect(await alice.deleteForEveryone('bob', secret.id), isTrue);

        device('bob', contacts: {'alice'}, store: bobStore);
        await alice.sendText('bob', 'ping');
        await _settle();

        expect(await bobStore.find('alice', secret.id), isNull);
        expect((await bobStore.messages('alice')).map((m) => m.text), ['ping']);
      },
    );
  });
}

/// A JPEG segment: its marker, its length, then its payload.
List<int> _segment(int marker, List<int> payload) {
  final length = payload.length + 2;
  return [0xFF, marker, length >> 8, length & 0xFF, ...payload];
}

/// A small JPEG with a GPS position in its APP1 (EXIF) segment.
Uint8List _jpegWithGps() => Uint8List.fromList([
  0xFF, 0xD8, //
  ..._segment(0xE0, [...'JFIF'.codeUnits, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
  ..._segment(0xE1, 'GPSLatitude=51.5074'.codeUnits),
  ..._segment(0xDB, List<int>.filled(65, 1)),
  ..._segment(0xDA, [1, 1, 0, 0, 63, 0]),
  0x12, 0x34, 0xFF, 0x00, 0x56, //
  0xFF, 0xD9,
]);
