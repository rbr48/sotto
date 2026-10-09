import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/file_storage.dart';
import 'package:sotto/chat/image_metadata.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

/// A well-formed SHA-256 digest: 64 lowercase hex characters.
const _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// One end of an in-memory data channel. Frames sent here arrive at [peer].
class _Link implements ChatTransport {
  final _incoming = StreamController<String>();
  final _incomingBinary = StreamController<Uint8List>();
  _Link? peer;
  bool connected = true;
  bool closed = false;

  /// Every text frame this end has sent, in order.
  final sentFrames = <String>[];

  @override
  bool send(String frame) {
    if (closed || !connected || peer == null || peer!.closed) return false;
    sentFrames.add(frame);
    peer!._incoming.add(frame);
    return true;
  }

  @override
  bool sendBinary(Uint8List data) {
    if (closed || !connected || peer == null || peer!.closed) return false;
    peer!._incomingBinary.add(data);
    return true;
  }

  @override
  Stream<String> get frames => _incoming.stream;

  @override
  Stream<Uint8List> get binaryFrames => _incomingBinary.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_incomingBinary.isClosed) await _incomingBinary.close();
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

  test(
    'a session that ends during a store write marks the message not sent',
    () async {
      final (a, b) = _pair();
      final secrets = _GatedSecrets();
      final aliceStore = ChatStore(secrets);
      final alice = ChatSession(
        contactId: 'bob',
        transport: a,
        store: aliceStore,
        clock: clock,
      );
      final aliceEvents = <ChatSessionEvent>[];
      alice.events.listen(aliceEvents.add);
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      unawaited(alice.start());
      await _settle();
      expect(alice.isReady, isTrue);

      secrets.hold();
      final pending = alice.sendText('in the middle of a write');
      await _settle();
      // The other side closes while this message is being written to storage.
      await bob.session.close();
      await _settle();
      secrets.release();
      await pending;
      await _settle();

      final stored = (await aliceStore.messages('bob')).single;
      expect(stored.state, ChatState.notSent);
      expect(aliceEvents.whereType<MessageNotSent>(), hasLength(1));
    },
  );

  test(
    'a contact removed mid-chat: nothing more is stored, and the session ends',
    () async {
      final (a, b) = _pair();
      var stillAContact = true;
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = ChatSession(
        contactId: 'bob',
        transport: a,
        store: aliceStore,
        clock: clock,
        isContact: () => stillAContact,
      );
      unawaited(alice.start());
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      stillAContact = false;
      await bob.session.sendText('after the removal');
      await _settle();

      expect(alice.isEnded, isTrue);
      expect(await aliceStore.messages('bob'), isEmpty);
    },
  );

  test('typing indicators are delivered to the peer', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    alice.session.sendTyping(true);
    await _settle();

    final typingEvent = bob.events.whereType<PeerTyping>().lastOrNull;
    expect(typingEvent?.typing, isTrue);

    alice.session.sendTyping(false);
    await _settle();

    final stopTypingEvent = bob.events.whereType<PeerTyping>().lastOrNull;
    expect(stopTypingEvent?.typing, isFalse);
  });

  test('read receipts update message state to ChatState.read', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    final sent = await alice.session.sendText('Read this please');
    await _settle();

    expect(
      (await alice.store.find('bob', sent.id))?.state,
      ChatState.delivered,
    );

    bob.session.sendReadReceipts([sent.id]);
    await _settle();

    expect((await alice.store.find('bob', sent.id))?.state, ChatState.read);
    final readEvent = alice.events.whereType<MessagesRead>().lastOrNull;
    expect(readEvent?.ids, [sent.id]);
  });

  test(
    'a received file is kept encrypted, with its key on the message',
    () async {
      final sodium = await SottoCrypto.init();
      final root = Directory.systemTemp.createTempSync('sotto_received_');
      addTearDown(() => root.deleteSync(recursive: true));
      final files = ReceivedFileStore(
        sodium: sodium,
        directory: () async => root,
      );

      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side(
        'bob',
        'alice',
        b,
        clock: clock,
        sharedStore: ChatStore(MemorySecretStore(), files: files),
      )..start();
      await _settle();

      // Several chunks, so the file really is streamed.
      final bytes = Uint8List.fromList(
        List.generate(40000, (i) => (i * 7) % 251),
      );
      final offer = await alice.session.offerFile(
        name: 'notes.txt',
        bytes: bytes,
        mime: 'text/plain',
      );
      await _settle();
      await bob.session.acceptFile(offer.fileId!);

      // Encrypting writes to disk, which the settle loop does not wait for.
      var received = await bob.store.find('alice', offer.fileId!);
      for (var i = 0; i < 400 && received?.fileStatus != 'completed'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        received = await bob.store.find('alice', offer.fileId!);
      }

      expect(received?.fileStatus, 'completed');
      expect(received?.fileKey, isNotNull);
      final done = received!;
      expect(await bob.store.readFile(done), bytes);

      final onDisk = File('${root.path}/${done.filePath}').readAsBytesSync();
      expect(onDisk.length, greaterThan(bytes.length));
      expect(_contains(onDisk, bytes.sublist(0, 64)), isFalse);
    },
  );

  test(
    'an image is sent without its metadata, and the peer keeps the picture',
    () async {
      final sodium = await SottoCrypto.init();
      final root = Directory.systemTemp.createTempSync('sotto_image_');
      addTearDown(() => root.deleteSync(recursive: true));
      final files = ReceivedFileStore(
        sodium: sodium,
        directory: () async => root,
      );

      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side(
        'bob',
        'alice',
        b,
        clock: clock,
        sharedStore: ChatStore(MemorySecretStore(), files: files),
      )..start();
      await _settle();

      final photo = _jpegWithGps();
      final expected = ImageMetadata.clean(photo, 'image/jpeg');
      final offer = await alice.session.offerFile(
        name: 'photo.jpg',
        bytes: photo,
        mime: 'image/jpeg',
      );
      expect(offer.fileSize, expected.length);
      await _settle();
      await bob.session.acceptFile(offer.fileId!);

      // Encrypting writes to disk, which the settle loop does not wait for.
      var received = await bob.store.find('alice', offer.fileId!);
      for (var i = 0; i < 400 && received?.fileStatus != 'completed'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        received = await bob.store.find('alice', offer.fileId!);
      }

      expect(received?.fileStatus, 'completed');
      final sent = await bob.store.readFile(received!);
      expect(sent, expected);
      expect(_contains(sent, _ascii('GPSLatitude')), isFalse);
      expect(sent.first, 0xFF);
      expect(sent[1], 0xD8);
    },
  );

  test('a file of a blocked type is refused, and nothing is sent', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();
    final sentBefore = a.sentFrames.length;

    for (final name in ['run.EXE ', 'setup.exe.']) {
      await expectLater(
        alice.session.offerFile(
          name: name,
          bytes: Uint8List.fromList([1, 2, 3]),
          mime: 'application/octet-stream',
        ),
        throwsA(isA<ArgumentError>()),
        reason: name,
      );
    }
    await _settle();

    expect(a.sentFrames.length, sentBefore);
    expect(await alice.store.messages('bob'), isEmpty);
    expect(await bob.store.messages('alice'), isEmpty);
  });

  test('an offer of a blocked type is declined, and nothing is kept', () async {
    final (a, b) = _pair();
    _Side('alice', 'bob', a, clock: clock).start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    // A peer that does not check its own names sends one anyway.
    final id = _id(60);
    a.send(
      ChatFrames.encode(
        FileOfferFrame(
          id: id,
          name: 'malware.exe',
          size: 100,
          mime: 'application/octet-stream',
          sha256: _digest,
          chunks: 1,
        ),
      ),
    );
    await _settle();

    expect((await bob.store.find('alice', id))?.fileStatus, 'declined');
    expect(bob.ofType<FileOfferReceived>(), isEmpty);
    expect(b.sentFrames, contains(ChatFrames.encode(FileDeclineFrame(id: id))));
  });

  test('an empty file and an image that cannot be read are refused', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    _Side('bob', 'alice', b, clock: clock).start();
    await _settle();

    await expectLater(
      alice.session.offerFile(
        name: 'empty.txt',
        bytes: Uint8List(0),
        mime: 'text/plain',
      ),
      throwsA(isA<ArgumentError>()),
    );
    // A JPEG whose first segment claims a length of one.
    await expectLater(
      alice.session.offerFile(
        name: 'broken.jpg',
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01]),
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
      alice.session.offerFile(
        name: 'animation.gif',
        bytes: Uint8List.fromList('GIF89a'.codeUnits),
        mime: 'image/gif',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await alice.store.messages('bob'), isEmpty);
  });
}

/// A JPEG segment: its marker, its length, then its payload.
Uint8List _segment(int marker, List<int> payload) {
  final length = payload.length + 2;
  return Uint8List.fromList([
    0xFF,
    marker,
    length >> 8,
    length & 0xFF,
    ...payload,
  ]);
}

/// The bytes of [parts], one after another.
Uint8List _join(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List _ascii(String text) => Uint8List.fromList(text.codeUnits);

/// A small JPEG with a GPS position in its APP1 (EXIF) segment.
Uint8List _jpegWithGps() => _join([
  [0xFF, 0xD8],
  _segment(0xE0, [...'JFIF'.codeUnits, 0x00, 0x01, 0x01, 0, 0, 1, 0, 1, 0, 0]),
  _segment(0xE1, 'GPSLatitude=51.5074'.codeUnits),
  _segment(0xDB, List<int>.filled(65, 1)),
  _segment(0xDA, [1, 1, 0, 0, 63, 0]),
  [0x12, 0x34, 0xFF, 0x00, 0x56],
  [0xFF, 0xD9],
]);

/// Whether [needle] appears in [haystack].
bool _contains(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var same = true;
    for (var j = 0; j < needle.length && same; j++) {
      same = haystack[i + j] == needle[j];
    }
    if (same) return true;
  }
  return false;
}

/// A store whose writes can be held, to end a session in the middle of one.
class _GatedSecrets extends MemorySecretStore {
  Completer<void>? _gate;

  void hold() => _gate = Completer<void>();

  void release() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<void> write(String key, String value) async {
    final gate = _gate;
    if (gate != null) await gate.future;
    await super.write(key, value);
  }
}
