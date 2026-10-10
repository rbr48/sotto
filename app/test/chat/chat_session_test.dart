import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/file_storage.dart';
import 'package:sotto/chat/image_metadata.dart';
import 'package:sotto/chat/voice/voice_format.dart';
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

  /// Binary chunks this end has sent.
  int binarySent = 0;

  /// After this many chunks, [sendBinary] refuses (null: never).
  int? refuseBinaryAfter;

  /// What [bufferedAmountNow] reports next, one value per call; 0 once empty.
  final bufferedReports = <int>[];

  /// How often [bufferedAmountNow] was asked.
  int bufferedAsks = 0;

  @override
  bool sendBinary(Uint8List data) {
    if (closed || !connected || peer == null || peer!.closed) return false;
    final refuseAfter = refuseBinaryAfter;
    if (refuseAfter != null && binarySent >= refuseAfter) return false;
    binarySent++;
    peer!._incomingBinary.add(data);
    return true;
  }

  /// The cached value: always says the buffer is empty, as a stale native
  /// value can.
  @override
  int get bufferedAmount => 0;

  @override
  Future<int> bufferedAmountNow() async {
    bufferedAsks++;
    return bufferedReports.isEmpty ? 0 : bufferedReports.removeAt(0);
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

/// An MPEG-4 audio file: an `ftyp` box with the major brand `M4A `, then
/// [length] bytes of audio.
Uint8List _m4a([int length = 64]) => Uint8List.fromList([
  0, 0, 0, 0x18, //
  ...'ftyp'.codeUnits,
  ...'M4A '.codeUnits,
  0, 0, 0, 0,
  ...'isom'.codeUnits,
  ...List<int>.filled(length, 7),
]);

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

  void start({
    List<ChatMessage> resend = const [],
    bool Function()? autoAccept,
    Future<void> Function()? bufferWait,
    int maxFileBytes = maxFileSizeNative,
  }) {
    session = ChatSession(
      contactId: contact,
      transport: link,
      store: store,
      clock: clock,
      newId: () => _id(100 + (_ids++)),
      autoAcceptFiles: autoAccept ?? () => false,
      bufferWait: bufferWait,
      maxFileBytes: maxFileBytes,
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

  test('an image over the size limit is offered when its metadata makes it '
      'fit', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    _Side('bob', 'alice', b, clock: clock).start();
    await _settle();

    // More than the limit, nearly all of it APP1 metadata: each segment is the
    // largest a JPEG segment can be. Once the metadata is removed, the image
    // is four bytes, so the limit applies to what is sent, not to the raw file.
    final segment = Uint8List(65537)
      ..fillRange(0, 65537, 0x20)
      ..[0] = 0xFF
      ..[1] = 0xE1
      ..[2] = 0xFF
      ..[3] = 0xFF;
    final count = maxFileSizeNative ~/ segment.length + 2;
    final photo = _join([
      [0xFF, 0xD8],
      for (var i = 0; i < count; i++) segment,
      [0xFF, 0xD9],
    ]);
    expect(photo.length, greaterThan(maxFileSizeNative));

    final offer = await alice.session.offerFile(
      name: 'big.jpg',
      bytes: photo,
      mime: 'image/jpeg',
    );
    expect(offer.fileSize, 4);
  });

  test('a file of a blocked type is refused, and nothing is sent', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();
    final sentBefore = a.sentFrames.length;

    for (final name in [
      'run.EXE ',
      'setup.exe.',
      'setup.msixbundle',
      'deck.ppsm',
      'tool.xlam',
    ]) {
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

  test('a colon in a name is kept as a plain name, not a stream', () async {
    final (a, b) = _pair();
    final alice = _Side('alice', 'bob', a, clock: clock)..start();
    _Side('bob', 'alice', b, clock: clock).start();
    await _settle();

    final note = await alice.session.offerFile(
      name: 'Notes for acme.com: final.pdf',
      bytes: Uint8List.fromList([1, 2, 3]),
      mime: 'application/pdf',
    );
    expect(note.fileName, 'Notes for acme.com_ final.pdf');

    final stream = await alice.session.offerFile(
      name: r'setup.exe::$DATA',
      bytes: Uint8List.fromList([1, 2, 3]),
      mime: 'application/octet-stream',
    );
    expect(stream.fileName, r'setup.exe__$DATA');
  });

  group('voice notes and plain audio', () {
    test(
      'a plain audio file is an ordinary file, not a refused voice note',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();

        final message = await alice.session.offerFile(
          name: 'song.mp3',
          bytes: Uint8List.fromList(List.filled(1000, 1)),
          mime: 'audio/mpeg',
        );
        await _settle();

        expect(message.voiceNote, isFalse);
        final received = await bob.store.find('alice', message.id);
        expect(received?.fileStatus, 'offered');
        expect(received?.voiceNote, isFalse);
        expect(bob.ofType<FileOfferReceived>(), hasLength(1));
        expect(
          b.sentFrames,
          isNot(contains(ChatFrames.encode(FileDeclineFrame(id: message.id)))),
        );
      },
    );

    test('a plain audio file of 20 MiB is sent up to the file limit', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      final size = 20 * 1024 * 1024;
      final message = await alice.session.offerFile(
        name: 'trip.wav',
        bytes: Uint8List(size),
        mime: 'audio/wav',
      );
      await _settle();

      expect(message.fileSize, size);
      expect(
        (await bob.store.find('alice', message.id))?.fileStatus,
        'offered',
      );
    });

    test('the sender refuses a voice note over its cap or misnamed', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      _Side('bob', 'alice', b, clock: clock).start();
      await _settle();

      await expectLater(
        alice.session.offerFile(
          name: 'voice-1.wav',
          bytes: Uint8List(maxVoiceWavBytes + 1),
          mime: 'audio/wav',
          voice: true,
        ),
        throwsArgumentError,
      );
      await expectLater(
        alice.session.offerFile(
          name: 'voice-1.m4a',
          bytes: Uint8List(maxVoiceAacBytes + 1),
          mime: 'audio/mp4',
          voice: true,
        ),
        throwsArgumentError,
      );
      await expectLater(
        alice.session.offerFile(
          name: 'song.mp3',
          bytes: _m4a(),
          mime: 'audio/mp4',
          voice: true,
        ),
        throwsArgumentError,
      );
    });

    test(
      'a voice note from a contact downloads at once, without a tap',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();

        final message = await alice.session.offerFile(
          name: 'voice-1.m4a',
          bytes: _m4a(2000),
          mime: 'audio/mp4',
          voice: true,
        );
        await _settle();

        expect(message.voiceNote, isTrue);
        expect(bob.ofType<FileOfferReceived>(), hasLength(1));
        expect(
          b.sentFrames,
          contains(ChatFrames.encode(FileAcceptFrame(id: message.id))),
        );
        final received = await bob.store.find('alice', message.id);
        expect(received?.voiceNote, isTrue);
        expect(received?.fileStatus, 'completed');
        expect(bob.store.hasVoice(received!), isTrue);
      },
    );

    test(
      'a voice offer named for another type is declined by the receiver',
      () async {
        final (a, b) = _pair();
        _Side('alice', 'bob', a, clock: clock).start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();

        // A peer that does not check its own names sends one anyway.
        final id = _id(61);
        a.send(
          ChatFrames.encode(
            FileOfferFrame(
              id: id,
              name: 'song.mp3',
              size: 100,
              mime: 'audio/mp4',
              sha256: _digest,
              chunks: 1,
              voice: true,
            ),
          ),
        );
        await _settle();

        expect((await bob.store.find('alice', id))?.fileStatus, 'declined');
        expect(bob.ofType<FileOfferReceived>(), isEmpty);
        expect(
          b.sentFrames,
          contains(ChatFrames.encode(FileDeclineFrame(id: id))),
        );
      },
    );

    test(
      'a voice offer over its type cap is declined by the receiver',
      () async {
        final (a, b) = _pair();
        _Side('alice', 'bob', a, clock: clock).start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();

        final id = _id(62);
        final size = maxVoiceAacBytes + 1;
        a.send(
          ChatFrames.encode(
            FileOfferFrame(
              id: id,
              name: 'voice-62.m4a',
              size: size,
              mime: 'audio/mp4',
              sha256: _digest,
              chunks: (size + fileChunkSize - 1) ~/ fileChunkSize,
              voice: true,
            ),
          ),
        );
        await _settle();

        expect((await bob.store.find('alice', id))?.fileStatus, 'declined');
        expect(bob.ofType<FileOfferReceived>(), isEmpty);
      },
    );
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

  test(
    'a name blocked only once cleaned is refused and nothing is sent',
    () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      _Side('bob', 'alice', b, clock: clock).start();
      await _settle();
      final sentBefore = a.sentFrames.length;

      for (final name in ['${'x' * 100}.exe${' ' * 40}x']) {
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
    },
  );

  test('an offer whose name is blocked as sent, but not once cleaned, is '
      'declined', () async {
    final (a, b) = _pair();
    _Side('alice', 'bob', a, clock: clock).start();
    final bob = _Side('bob', 'alice', b, clock: clock)..start();
    await _settle();

    // A peer that does not check its own names sends this anyway. Cleaning
    // turns "..exe" into "exe", which is not blocked, so the name as sent is
    // what must be judged.
    final names = ['..exe'];
    for (var i = 0; i < names.length; i++) {
      final id = _id(70 + i);
      a.send(
        ChatFrames.encode(
          FileOfferFrame(
            id: id,
            name: names[i],
            size: 100,
            mime: 'application/octet-stream',
            sha256: _digest,
            chunks: 1,
          ),
        ),
      );
      await _settle();

      expect(
        (await bob.store.find('alice', id))?.fileStatus,
        'declined',
        reason: names[i],
      );
      expect(
        b.sentFrames,
        contains(ChatFrames.encode(FileDeclineFrame(id: id))),
        reason: names[i],
      );
    }
    expect(bob.ofType<FileOfferReceived>(), isEmpty);
  });

  test(
    'an offer stored under a blocked name is declined when accepted',
    () async {
      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      // An offer kept by an older build, which did not block this type.
      final id = _id(80);
      await bob.store.add(
        ChatMessage(
          id: id,
          contactId: 'alice',
          outgoing: false,
          ts: clock().millisecondsSinceEpoch,
          text: 'page.html',
          state: ChatState.received,
          read: false,
          fileId: id,
          fileName: 'page.html',
          fileSize: 100,
          fileMime: 'text/html',
          fileSha256: _digest,
          fileStatus: 'offered',
        ),
      );
      await bob.session.acceptFile(id);
      await _settle();

      expect((await bob.store.find('alice', id))?.fileStatus, 'declined');
      expect(
        b.sentFrames,
        contains(ChatFrames.encode(FileDeclineFrame(id: id))),
      );
      expect(
        b.sentFrames,
        isNot(contains(ChatFrames.encode(FileAcceptFrame(id: id)))),
      );
    },
  );

  test(
    'a declined offer keeps nothing on disk, and its chunks are ignored',
    () async {
      final sodium = await SottoCrypto.init();
      final root = Directory.systemTemp.createTempSync('sotto_declined_');
      addTearDown(() => root.deleteSync(recursive: true));
      final files = ReceivedFileStore(
        sodium: sodium,
        directory: () async => root,
      );

      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      final bob = _Side(
        'bob',
        'alice',
        b,
        clock: clock,
        sharedStore: ChatStore(MemorySecretStore(), files: files),
      )..start();
      await _settle();

      final id = _id(90);
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
      // The sender carries on as if the offer had been accepted.
      a.sendBinary(
        ChatFrames.encodeChunk(
          fileId: id,
          chunkIndex: 0,
          payload: List<int>.filled(100, 7),
        ),
      );
      a.send(ChatFrames.encode(FileDoneFrame(id: id)));
      await _settle();

      expect((await bob.store.find('alice', id))?.fileStatus, 'declined');
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  group('review fixes', () {
    /// An offer frame from Alice's side for a file of [size] bytes.
    String offerFrame(String id, int size, {String name = 'notes.txt'}) =>
        ChatFrames.encode(
          FileOfferFrame(
            id: id,
            name: name,
            size: size,
            mime: 'text/plain',
            sha256: _digest,
            chunks: (size + fileChunkSize - 1) ~/ fileChunkSize,
          ),
        );

    bool accepted(_Link link, String id) =>
        link.sentFrames.contains(ChatFrames.encode(FileAcceptFrame(id: id)));

    test('a file from a contact is not downloaded unless the setting is on, '
        'and a change applies to the next offer', () async {
      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      var autoOn = false;
      final bob = _Side('bob', 'alice', b, clock: clock)
        ..start(autoAccept: () => autoOn);
      await _settle();

      a.send(offerFrame(_id(1), 100));
      await _settle();
      expect(accepted(b, _id(1)), isFalse);
      expect((await bob.store.find('alice', _id(1)))?.fileStatus, 'offered');

      autoOn = true;
      a.send(offerFrame(_id(2), 100));
      await _settle();
      expect(accepted(b, _id(2)), isTrue);
      expect(accepted(b, _id(1)), isFalse);
    });

    test(
      'a voice note from a contact downloads with the setting off',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();

        final note = await alice.session.offerFile(
          name: 'voice.m4a',
          bytes: _m4a(),
          mime: 'audio/mp4',
          voice: true,
        );
        await _settle();
        expect(
          (await bob.store.find('alice', note.id))?.fileStatus,
          'completed',
        );
      },
    );

    test('with the setting on, only files up to the limit download', () async {
      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      _Side('bob', 'alice', b, clock: clock).start(autoAccept: () => true);
      await _settle();

      a.send(offerFrame(_id(1), ChatSession.autoAcceptMaxBytes));
      a.send(offerFrame(_id(2), ChatSession.autoAcceptMaxBytes + 1));
      await _settle();
      expect(accepted(b, _id(1)), isTrue);
      expect(accepted(b, _id(2)), isFalse);
    });

    test('with the setting on, at most two transfers run; others wait to be '
        'accepted by hand', () async {
      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      final bob = _Side('bob', 'alice', b, clock: clock)
        ..start(autoAccept: () => true);
      await _settle();

      for (var i = 1; i <= 3; i++) {
        a.send(offerFrame(_id(i), 100));
      }
      await _settle();
      expect(accepted(b, _id(1)), isTrue);
      expect(accepted(b, _id(2)), isTrue);
      expect(accepted(b, _id(3)), isFalse);
      expect((await bob.store.find('alice', _id(3)))?.fileStatus, 'offered');

      // By hand it is accepted.
      await bob.session.acceptFile(_id(3));
      expect(accepted(b, _id(3)), isTrue);
    });

    test('with the setting on, a session downloads at most its budget without '
        'asking', () async {
      final (a, b) = _pair();
      _Side('alice', 'bob', a, clock: clock).start();
      _Side('bob', 'alice', b, clock: clock).start(autoAccept: () => true);
      await _settle();

      const size = ChatSession.autoAcceptMaxBytes;
      const fits = ChatSession.autoAcceptBudgetBytes ~/ size;
      for (var i = 1; i <= fits + 1; i++) {
        a.send(offerFrame(_id(i), size));
        await _settle();
        // The sender cancels, so the transfer does not hold a slot.
        a.send(ChatFrames.encode(FileCancelFrame(id: _id(i))));
        await _settle();
      }
      for (var i = 1; i <= fits; i++) {
        expect(accepted(b, _id(i)), isTrue, reason: 'offer $i');
      }
      expect(accepted(b, _id(fits + 1)), isFalse);
    });

    test('an accept after the sender cancelled sends nothing', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      _Side('bob', 'alice', b, clock: clock).start();
      await _settle();

      final offer = await alice.session.offerFile(
        name: 'notes.txt',
        bytes: Uint8List.fromList(List.filled(40000, 3)),
        mime: 'text/plain',
      );
      await _settle();
      await alice.session.cancelFile(offer.id);
      await _settle();
      b.send(ChatFrames.encode(FileAcceptFrame(id: offer.id)));
      await _settle();

      expect(a.binarySent, 0);
      expect(
        (await alice.store.find('bob', offer.id))?.fileStatus,
        'cancelled',
      );
    });

    test('an accept after a decline sends nothing', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      final offer = await alice.session.offerFile(
        name: 'notes.txt',
        bytes: Uint8List.fromList(List.filled(40000, 3)),
        mime: 'text/plain',
      );
      await _settle();
      await bob.session.declineFile(offer.id);
      await _settle();
      b.send(ChatFrames.encode(FileAcceptFrame(id: offer.id)));
      await _settle();

      expect(a.binarySent, 0);
      expect((await alice.store.find('bob', offer.id))?.fileStatus, 'declined');
    });

    test('a second accept does not send the file again', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      final offer = await alice.session.offerFile(
        name: 'notes.txt',
        bytes: Uint8List.fromList(List.filled(40000, 3)),
        mime: 'text/plain',
      );
      await _settle();
      await bob.session.acceptFile(offer.id);
      b.send(ChatFrames.encode(FileAcceptFrame(id: offer.id)));
      await _settle();
      b.send(ChatFrames.encode(FileAcceptFrame(id: offer.id)));
      await _settle();

      expect(a.binarySent, 3);
      expect(
        (await alice.store.find('bob', offer.id))?.fileStatus,
        'completed',
      );
    });

    test(
      'an accept for a file not offered in this session sends nothing',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        _Side('bob', 'alice', b, clock: clock).start();
        await _settle();

        // An outgoing file from an earlier session, whose bytes are still here.
        final id = _id(60);
        final bytes = Uint8List.fromList([1, 2, 3]);
        alice.store.rememberFile(id, bytes);
        await alice.store.add(
          ChatMessage(
            id: id,
            contactId: 'bob',
            outgoing: true,
            ts: 1,
            text: 'old.txt',
            state: ChatState.sending,
            fileId: id,
            fileName: 'old.txt',
            fileSize: 3,
            fileStatus: 'failed',
            filePath: 'web:$id',
          ),
        );
        b.send(ChatFrames.encode(FileAcceptFrame(id: id)));
        await _settle();

        expect(a.binarySent, 0);
        expect((await alice.store.find('bob', id))?.fileStatus, 'failed');
      },
    );

    test('chunks wait while the channel really is full, asked before each '
        'chunk', () async {
      final (a, b) = _pair();
      var waits = 0;
      final alice = _Side('alice', 'bob', a, clock: clock)
        ..start(
          bufferWait: () async {
            waits++;
          },
        );
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      final offer = await alice.session.offerFile(
        name: 'notes.txt',
        bytes: Uint8List.fromList(List.filled(40000, 3)),
        mime: 'text/plain',
      );
      await _settle();
      // The cached value says empty; the channel says full, twice.
      a.bufferedReports.addAll([
        ChatSession.maxBufferedBytes + 1,
        ChatSession.maxBufferedBytes + 1,
      ]);
      await bob.session.acceptFile(offer.id);
      await _settle();

      expect(waits, 2);
      // Three chunks, each asked for (two of the asks for the first chunk
      // were full).
      expect(a.bufferedAsks, 5);
      expect(a.binarySent, 3);
      expect(
        (await alice.store.find('bob', offer.id))?.fileStatus,
        'completed',
      );
    });

    test('a chunk the channel refuses stops the transfer as failed', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();

      final offer = await alice.session.offerFile(
        name: 'notes.txt',
        bytes: Uint8List.fromList(List.filled(40000, 3)),
        mime: 'text/plain',
      );
      await _settle();
      a.refuseBinaryAfter = 1;
      await bob.session.acceptFile(offer.id);
      await _settle();

      expect(a.binarySent, 1);
      expect((await alice.store.find('bob', offer.id))?.fileStatus, 'failed');
      expect(
        a.sentFrames,
        isNot(contains(ChatFrames.encode(FileDoneFrame(id: offer.id)))),
      );
      expect(alice.ofType<FileTransferFailed>().single.reason, 'failed');
      expect(
        (await bob.store.find('alice', offer.id))?.fileStatus,
        'cancelled',
      );
    });

    test('a queued file is offered once when the other side is ready, never '
        'as a text', () async {
      final (a, b) = _pair();
      final aliceStore = ChatStore(MemorySecretStore());
      final id = _id(70);
      final bytes = Uint8List.fromList(List.filled(100, 9));
      final queued = await aliceStore.keepOutgoingFile(
        ChatMessage(
          id: id,
          contactId: 'bob',
          outgoing: true,
          ts: 1,
          text: 'notes.txt',
          state: ChatState.queued,
          fileId: id,
          fileName: 'notes.txt',
          fileSize: bytes.length,
          fileMime: 'text/plain',
          fileStatus: 'offered',
        ),
        bytes,
      );
      await aliceStore.add(queued);
      expect(queued.filePath, 'web:$id');

      final alice = _Side(
        'alice',
        'bob',
        a,
        clock: clock,
        sharedStore: aliceStore,
      )..start(resend: [queued]);
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      // Asked again, as the outbox flush does: nothing more is offered.
      expect(await alice.session.offerStoredFile(queued), isFalse);
      await _settle();

      final offers = a.sentFrames
          .map(ChatFrames.decode)
          .whereType<FileOfferFrame>()
          .toList();
      expect(offers.map((f) => f.id), [id]);
      expect(
        a.sentFrames.map(ChatFrames.decode).whereType<MessageFrame>(),
        isEmpty,
      );
      expect((await aliceStore.find('bob', id))?.state, ChatState.sending);

      final received = await bob.store.messages('alice');
      expect(received.single.isAttachment, isTrue);
      await bob.session.acceptFile(id);
      await _settle();
      expect(
        (await bob.store.readFile((await bob.store.find('alice', id))!)),
        bytes,
      );
    });

    test('a session that ends before the other side is ready leaves a queued '
        'file queued', () async {
      final (a, _) = _pair();
      final aliceStore = ChatStore(MemorySecretStore());
      final id = _id(71);
      await aliceStore.add(
        await aliceStore.keepOutgoingFile(
          ChatMessage(
            id: id,
            contactId: 'bob',
            outgoing: true,
            ts: 1,
            text: 'notes.txt',
            state: ChatState.queued,
            fileId: id,
            fileName: 'notes.txt',
            fileSize: 3,
            fileStatus: 'offered',
          ),
          Uint8List.fromList([1, 2, 3]),
        ),
      );
      final alice = _Side(
        'alice',
        'bob',
        a,
        clock: clock,
        sharedStore: aliceStore,
      )..start();
      await _settle();
      await alice.session.close();
      await _settle();

      final after = await aliceStore.find('bob', id);
      expect(after?.state, ChatState.queued);
      expect(after?.fileStatus, 'offered');
    });

    test('the live path refuses what the shared check refuses', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)
        ..start(maxFileBytes: 10);
      _Side('bob', 'alice', b, clock: clock).start();
      await _settle();

      await expectLater(
        alice.session.offerFile(
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
      await expectLater(
        alice.session.offerFile(
          name: 'photo.heic',
          bytes: Uint8List.fromList([0, 0, 0, 0x18, 1, 2]),
          mime: 'image/heic',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('replies, forwards, reactions, edits and deletes', () {
    const minute = 60 * 1000;

    /// A hello from a contact that lists every feature this app has.
    const helloAll =
        '{"t":"hello","v":1,"features":["reply","fwd","react","edit","delete"]}';

    test(
      'both sides list the features, so a reply and a forward arrive',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();

        final first = await alice.session.sendText('Are you free?');
        await _settle();
        final reply = await alice.session.sendText(
          'Yes',
          replyTo: (id: first.id, text: 'Are you free?'),
          forwarded: true,
        );
        await _settle();

        final hello = ChatFrames.decode(a.sentFrames.first) as HelloFrame;
        expect(hello.features, unorderedEquals(ChatFrames.features));
        final received = (await bob.store.find('alice', reply.id))!;
        expect(received.replyTo, (id: first.id, text: 'Are you free?'));
        expect(received.forwarded, isTrue);
        expect(received.outgoing, isFalse);
      },
    );

    test(
      'a contact whose hello lists no features gets a plain message',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        await _settle();
        final heard = <String>[];
        b.frames.listen(heard.add);
        b.send('{"t":"hello","v":1}');
        await _settle();

        await alice.session.sendText(
          'Yes',
          replyTo: (id: _id(9), text: 'Are you free?'),
          forwarded: true,
        );
        await _settle();

        final sent = heard.singleWhere((f) => f.contains('"t":"msg"'));
        expect(sent, isNot(contains('"reply"')));
        expect(sent, isNot(contains('"fwd"')));
        final message = ChatFrames.decode(sent) as MessageFrame;
        expect(message.text, 'Yes');
        expect(message.reply, isNull);
        expect(message.forwarded, isFalse);
      },
    );

    test(
      'a contact that lists only forwards gets the mark, not the quote',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        await _settle();
        final heard = <String>[];
        b.frames.listen(heard.add);
        b.send('{"t":"hello","v":1,"features":["fwd"]}');
        await _settle();

        await alice.session.sendText(
          'Yes',
          replyTo: (id: _id(9), text: 'Are you free?'),
          forwarded: true,
        );
        await _settle();

        final message = ChatFrames.decode(
          heard.singleWhere((f) => f.contains('"t":"msg"')),
        ) as MessageFrame;
        expect(message.reply, isNull);
        expect(message.forwarded, isTrue);
      },
    );

    test('an edit from the contact applies up to 15 minutes after the message, and not after', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(1), ts: sentAt, text: 'first try'),
        ),
      );
      await _settle();

      // Each edit is made, and arrives, at the time it names: this device's
      // clock is set to that time first.
      void at(int ms) =>
          now = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

      at(sentAt + 10 * minute);
      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt + 10 * minute, text: 'fixed'),
        ),
      );
      await _settle();
      var stored = (await bob.store.find('alice', _id(1)))!;
      expect(stored.text, 'fixed');
      expect(stored.editedAt, sentAt + 10 * minute);
      expect(stored.outgoing, isFalse);

      // Exactly 15 minutes after the message is still inside the window.
      at(sentAt + 15 * minute);
      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt + 15 * minute, text: 'at the limit'),
        ),
      );
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.text, 'at the limit');

      // Sixteen minutes after the message: refused, and nothing changes.
      at(sentAt + 16 * minute);
      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt + 16 * minute, text: 'too late'),
        ),
      );
      await _settle();
      stored = (await bob.store.find('alice', _id(1)))!;
      expect(stored.text, 'at the limit');
      expect(stored.editedAt, sentAt + 15 * minute);

      // An edit dated before the message is refused too.
      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt - 1, text: 'before'),
        ),
      );
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.text, 'at the limit');
      expect(bob.session.isEnded, isFalse);
    });

    test('an edit or delete of the contact\'s own message is ignored; a reaction on it is kept', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      await _settle();
      final mine = await bob.session.sendText('mine');
      await _settle();

      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(EditFrame(id: mine.id, ts: sentAt, text: 'changed')),
      );
      a.send(ChatFrames.encode(DeleteFrame(id: mine.id, ts: sentAt)));
      a.send(
        ChatFrames.encode(
          ReactFrame(id: mine.id, emoji: '\u{1F44D}', ts: sentAt),
        ),
      );
      await _settle();

      final stored = (await bob.store.find('alice', mine.id))!;
      expect(stored.text, 'mine');
      expect(stored.editedAt, isNull);
      expect(stored.deletedForAll, isFalse);
      expect(stored.reactions, {'peer': '\u{1F44D}'});
    });

    test('a reaction, an edit or a delete from the contact tells the open chat which message changed', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(MessageFrame(id: _id(1), ts: sentAt, text: 'first')),
      );
      await _settle();
      expect(bob.ofType<MessageChanged>(), isEmpty);

      a.send(
        ChatFrames.encode(
          ReactFrame(id: _id(1), emoji: '\u{1F44D}', ts: sentAt),
        ),
      );
      a.send(
        ChatFrames.encode(
          ReactFrame(id: _id(9), emoji: '\u{1F44D}', ts: sentAt),
        ),
      );
      await _settle();
      a.send(
        ChatFrames.encode(EditFrame(id: _id(1), ts: sentAt, text: 'second')),
      );
      await _settle();
      a.send(ChatFrames.encode(DeleteFrame(id: _id(1), ts: sentAt)));
      await _settle();

      // The reaction on an unknown message changed nothing, so it tells no one.
      expect(bob.ofType<MessageChanged>().map((e) => e.id), [
        _id(1),
        _id(1),
        _id(1),
      ]);
    });

    test('a delete from the contact applies up to an hour after the message and keeps the record', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(MessageFrame(id: _id(1), ts: sentAt, text: 'secret')),
      );
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(2), ts: sentAt, text: 'too late to delete'),
        ),
      );
      a.send(
        ChatFrames.encode(
          ReactFrame(id: _id(1), emoji: '\u{1F44D}', ts: sentAt),
        ),
      );
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.reactions, {
        'peer': '\u{1F44D}',
      });

      now = DateTime.fromMillisecondsSinceEpoch(
        sentAt + 59 * minute,
        isUtc: true,
      );
      a.send(
        ChatFrames.encode(DeleteFrame(id: _id(1), ts: sentAt + 59 * minute)),
      );
      await _settle();
      now = DateTime.fromMillisecondsSinceEpoch(
        sentAt + 61 * minute,
        isUtc: true,
      );
      a.send(
        ChatFrames.encode(DeleteFrame(id: _id(2), ts: sentAt + 61 * minute)),
      );
      await _settle();

      final deleted = (await bob.store.find('alice', _id(1)))!;
      expect(deleted.deletedForAll, isTrue);
      expect(deleted.text, isEmpty);
      expect(deleted.reactions, isEmpty);
      final kept = (await bob.store.find('alice', _id(2)))!;
      expect(kept.deletedForAll, isFalse);
      expect(kept.text, 'too late to delete');

      // A deleted message takes no more reactions.
      now = DateTime.fromMillisecondsSinceEpoch(
        sentAt + 60 * minute,
        isUtc: true,
      );
      a.send(
        ChatFrames.encode(
          ReactFrame(id: _id(1), emoji: '\u{2764}', ts: sentAt + 60 * minute),
        ),
      );
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.reactions, isEmpty);
    });

    test('a reaction replaces the one before it, an empty one removes it, and one on an unknown message is ignored', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(MessageFrame(id: _id(1), ts: sentAt, text: 'hi')),
      );
      await _settle();

      Future<void> react(String id, String emoji) async {
        a.send(ChatFrames.encode(ReactFrame(id: id, emoji: emoji, ts: sentAt)));
        await _settle();
      }

      await react(_id(1), '\u{1F44D}');
      expect((await bob.store.find('alice', _id(1)))!.reactions, {
        'peer': '\u{1F44D}',
      });
      await react(_id(1), '\u{2764}️');
      expect((await bob.store.find('alice', _id(1)))!.reactions, {
        'peer': '\u{2764}️',
      });
      await react(_id(1), '');
      expect((await bob.store.find('alice', _id(1)))!.reactions, isEmpty);

      await react(_id(99), '\u{1F602}');
      expect(bob.session.isEnded, isFalse);
      expect(await bob.store.messages('alice'), hasLength(1));
      expect(await bob.store.contains('alice', _id(99)), isFalse);
    });

    test(
      'a pending reaction waits while the contact does not list it',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        await _settle();
        final heard = <String>[];
        b.frames.listen(heard.add);
        b.send('{"t":"hello","v":1,"features":["reply"]}');
        await _settle();

        await alice.store.add(
          ChatMessage(
            id: _id(1),
            contactId: 'bob',
            outgoing: false,
            ts: now.millisecondsSinceEpoch,
            text: 'hi',
            state: ChatState.received,
            read: false,
          ),
        );
        await alice.store.queueControl(
          'bob',
          ReactFrame(
            id: _id(1),
            emoji: '\u{1F44D}',
            ts: now.millisecondsSinceEpoch,
          ),
        );
        await alice.session.flushControls();
        await _settle();

        expect(heard.where((f) => f.contains('"t":"react"')), isEmpty);
        expect(await alice.store.pendingControls('bob'), hasLength(1));
      },
    );

    test(
      'a pending reaction is sent once the contact lists the feature',
      () async {
        final (a, b) = _pair();
        final alice = _Side('alice', 'bob', a, clock: clock)..start();
        final bob = _Side('bob', 'alice', b, clock: clock)..start();
        await _settle();
        // Bob's message, as each device keeps it.
        await bob.store.add(
          ChatMessage(
            id: _id(1),
            contactId: 'alice',
            outgoing: true,
            ts: now.millisecondsSinceEpoch,
            text: 'Lunch?',
            state: ChatState.read,
          ),
        );
        await alice.store.add(
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

        await alice.store.queueControl(
          'bob',
          ReactFrame(
            id: _id(1),
            emoji: '\u{1F44D}',
            ts: now.millisecondsSinceEpoch,
          ),
        );
        await alice.session.flushControls();
        await _settle();

        expect((await bob.store.find('alice', _id(1)))!.reactions, {
          'peer': '\u{1F44D}',
        });
        expect(await alice.store.pendingControls('bob'), isEmpty);
      },
    );

    test('an edit or delete dated more than five minutes ahead of this clock is refused', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(1), ts: sentAt, text: 'first try'),
        ),
      );
      await _settle();

      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt + 6 * minute, text: 'from ahead'),
        ),
      );
      a.send(
        ChatFrames.encode(DeleteFrame(id: _id(1), ts: sentAt + 6 * minute)),
      );
      await _settle();
      final kept = (await bob.store.find('alice', _id(1)))!;
      expect(kept.text, 'first try');
      expect(kept.editedAt, isNull);
      expect(kept.deletedForAll, isFalse);
      expect(bob.session.isEnded, isFalse);

      // Five minutes ahead is still within the allowance for two clocks that
      // differ.
      a.send(
        ChatFrames.encode(
          EditFrame(
            id: _id(1),
            ts: sentAt + 5 * minute,
            text: 'a little ahead',
          ),
        ),
      );
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.text, 'a little ahead');
    });

    test('an edit or delete more than seven days old by this clock is refused, though it is within its message\'s window', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      const week = 7 * 24 * 60 * minute;
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(1), ts: sentAt, text: 'a week old'),
        ),
      );
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(2), ts: sentAt, text: 'also a week old'),
        ),
      );
      await _settle();

      // Seven days and five minutes after the message: a control dated at the
      // message's own time is the oldest still accepted.
      now = DateTime.fromMillisecondsSinceEpoch(
        sentAt + week + 5 * minute,
        isUtc: true,
      );
      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt, text: 'at the limit'),
        ),
      );
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.text, 'at the limit');

      // One millisecond later it is refused, as a replayed edit or delete would
      // be. Both are inside the window of their message, which is not enough.
      now = DateTime.fromMillisecondsSinceEpoch(
        sentAt + week + 5 * minute + 1,
        isUtc: true,
      );
      a.send(
        ChatFrames.encode(EditFrame(id: _id(1), ts: sentAt, text: 'replayed')),
      );
      a.send(ChatFrames.encode(DeleteFrame(id: _id(2), ts: sentAt)));
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.text, 'at the limit');
      final kept = (await bob.store.find('alice', _id(2)))!;
      expect(kept.deletedForAll, isFalse);
      expect(kept.text, 'also a week old');
      expect(bob.session.isEnded, isFalse);
    });

    test('a message dated far ahead of this clock keeps the arrival time; one a little ahead keeps its own', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final arrived = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(1),
            ts: arrived + 60 * minute,
            text: 'from the future',
          ),
        ),
      );
      a.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(2),
            ts: arrived + 4 * minute,
            text: 'a little ahead',
          ),
        ),
      );
      await _settle();

      final far = (await bob.store.find('alice', _id(1)))!;
      expect(far.ts, arrived);
      expect(far.arrivedAt, arrived);
      expect((await bob.store.find('alice', _id(2)))!.ts, arrived + 4 * minute);
    });

    test('a deleted message\'s text is taken out of its quotes here, stored and still in the outbox', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(1), ts: sentAt, text: 'the door code is 4471'),
        ),
      );
      a.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(2),
            ts: sentAt,
            text: 'got it',
            reply: (id: _id(1), text: 'the door code is 4471'),
          ),
        ),
      );
      await _settle();
      // Bob's own reply to the same message is not acknowledged, so it waits
      // in his outbox.
      final mine = await bob.session.sendText(
        'the code, again',
        replyTo: (id: _id(1), text: 'the door code is 4471'),
      );
      await _settle();

      a.send(ChatFrames.encode(DeleteFrame(id: _id(1), ts: sentAt)));
      await _settle();
      expect((await bob.store.find('alice', _id(1)))!.deletedForAll, isTrue);
      expect((await bob.store.find('alice', _id(2)))!.replyTo, (
        id: _id(1),
        text: '',
      ));

      // The contact says hello again, so the outbox goes out once more: the
      // reply goes with its quote emptied.
      a.send(helloAll);
      await _settle();
      final again = b.sentFrames
          .map(ChatFrames.decode)
          .whereType<MessageFrame>()
          .where((f) => f.id == mine.id)
          .last;
      expect(again.text, 'the code, again');
      expect(again.reply, (id: _id(1), text: ''));
      expect((await bob.store.find('alice', mine.id))!.replyTo, (
        id: _id(1),
        text: '',
      ));
    });

    test('a peer\'s edit gives the stored replies to the edited message the new text', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(1), ts: sentAt, text: 'the door code is 4471'),
        ),
      );
      a.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(2),
            ts: sentAt,
            text: 'got it',
            reply: (id: _id(1), text: 'the door code is 4471'),
          ),
        ),
      );
      await _settle();

      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt, text: 'the door code is 4472'),
        ),
      );
      await _settle();

      expect(
        (await bob.store.find('alice', _id(1)))!.text,
        'the door code is 4472',
      );
      final reply = (await bob.store.find('alice', _id(2)))!;
      expect(reply.text, 'got it');
      expect(reply.replyTo, (id: _id(1), text: 'the door code is 4472'));
      expect(
        await bob.secrets.read(ChatStore.contactKey('alice')),
        isNot(contains('4471')),
      );
    });

    test('a peer\'s edit gives the unsent replies to the edited message the new text in the outbox', () async {
      final (a, b) = _pair();
      final bob = _Side('bob', 'alice', b, clock: clock)..start();
      await _settle();
      a.send(helloAll);
      await _settle();
      final sentAt = now.millisecondsSinceEpoch;
      a.send(
        ChatFrames.encode(
          MessageFrame(id: _id(1), ts: sentAt, text: 'the door code is 4471'),
        ),
      );
      await _settle();
      // Bob's reply to the same message is not acknowledged, so it waits in his
      // outbox.
      final mine = await bob.session.sendText(
        'the code, again',
        replyTo: (id: _id(1), text: 'the door code is 4471'),
      );
      await _settle();

      a.send(
        ChatFrames.encode(
          EditFrame(id: _id(1), ts: sentAt, text: 'the door code is 4472'),
        ),
      );
      await _settle();

      // The contact says hello again, so the outbox goes out once more: the
      // reply goes with the edited text in its quote.
      a.send(helloAll);
      await _settle();
      final again = b.sentFrames
          .map(ChatFrames.decode)
          .whereType<MessageFrame>()
          .where((f) => f.id == mine.id)
          .last;
      expect(again.text, 'the code, again');
      expect(again.reply, (id: _id(1), text: 'the door code is 4472'));
      expect((await bob.store.find('alice', mine.id))!.replyTo, (
        id: _id(1),
        text: 'the door code is 4472',
      ));
    });

    test('a reply that arrives after its message was edited here quotes the new text, stored and in the event', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      await _settle();
      b.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      await alice.store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: true,
          ts: sentAt,
          text: 'the door code is 4471',
          state: ChatState.delivered,
        ),
      );
      // Alice edits her message here. Bob's reply, written before he had the
      // edit, still quotes the old text when it arrives.
      await alice.store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(
          text: 'the door code is 4472',
          editedAt: sentAt + minute,
        ),
      );
      b.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(2),
            ts: sentAt,
            text: 'got it',
            reply: (id: _id(1), text: 'the door code is 4471'),
          ),
        ),
      );
      await _settle();

      final reply = (await alice.store.find('bob', _id(2)))!;
      expect(reply.text, 'got it');
      expect(reply.replyTo, (id: _id(1), text: 'the door code is 4472'));
      expect(alice.ofType<MessageReceived>().single.message.replyTo, (
        id: _id(1),
        text: 'the door code is 4472',
      ));
      expect(
        await alice.secrets.read(ChatStore.contactKey('bob')),
        isNot(contains('4471')),
      );
    });

    test('a reply that arrives after its message was deleted here quotes no text, and a quote of a message not held here keeps its text', () async {
      final (a, b) = _pair();
      final alice = _Side('alice', 'bob', a, clock: clock)..start();
      await _settle();
      b.send(helloAll);
      final sentAt = now.millisecondsSinceEpoch;
      await alice.store.add(
        ChatMessage(
          id: _id(1),
          contactId: 'bob',
          outgoing: true,
          ts: sentAt,
          text: 'the door code is 4471',
          state: ChatState.delivered,
        ),
      );
      // Alice deletes her message for everyone while Bob is offline. His reply
      // is sent later with the old text in its quote.
      await alice.store.changeMessage(
        'bob',
        _id(1),
        (m) => m.copyWith(text: '', deletedForAll: true, reactions: const {}),
      );
      b.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(2),
            ts: sentAt,
            text: 'got it',
            reply: (id: _id(1), text: 'the door code is 4471'),
          ),
        ),
      );
      b.send(
        ChatFrames.encode(
          MessageFrame(
            id: _id(3),
            ts: sentAt,
            text: 'and that one',
            reply: (id: _id(9), text: 'a message not held here'),
          ),
        ),
      );
      await _settle();

      final reply = (await alice.store.find('bob', _id(2)))!;
      expect(reply.text, 'got it');
      expect(reply.replyTo, (id: _id(1), text: ''));
      expect(alice.ofType<MessageReceived>().first.message.replyTo, (
        id: _id(1),
        text: '',
      ));
      expect((await alice.store.find('bob', _id(3)))!.replyTo, (
        id: _id(9),
        text: 'a message not held here',
      ));
      expect(
        await alice.secrets.read(ChatStore.contactKey('bob')),
        isNot(contains('4471')),
      );
    });
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
