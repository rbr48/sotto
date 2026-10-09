import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/crypto/encoding.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

void main() {
  group('frames round-trip', () {
    test('every frame type encodes and decodes to itself', () {
      final frames = <ChatFrame>[
        const HelloFrame(),
        MessageFrame(id: _id(1), ts: 1700000000000, text: 'Hello'),
        AckFrame(id: _id(1)),
        const ByeFrame(),
      ];
      for (final frame in frames) {
        final decoded = ChatFrames.decode(ChatFrames.encode(frame));
        expect(decoded.runtimeType, frame.runtimeType);
      }
      final message = ChatFrames.decode(
        ChatFrames.encode(MessageFrame(id: _id(2), ts: 5, text: 'Salaam')),
      ) as MessageFrame;
      expect(message.id, _id(2));
      expect(message.ts, 5);
      expect(message.text, 'Salaam');

      final typing = ChatFrames.decode(
        ChatFrames.encode(const TypingFrame(typing: true)),
      ) as TypingFrame;
      expect(typing.typing, true);

      final read = ChatFrames.decode(
        ChatFrames.encode(ReadFrame(ids: [_id(1), _id(2)])),
      ) as ReadFrame;
      expect(read.ids, [_id(1), _id(2)]);
    });

    test('the encoding is the documented JSON', () {
      expect(ChatFrames.encode(const HelloFrame()), '{"t":"hello","v":1}');
      expect(ChatFrames.encode(const ByeFrame()), '{"t":"bye"}');
      expect(
        ChatFrames.encode(AckFrame(id: _id(3))),
        '{"t":"ack","id":"${_id(3)}"}',
      );
      expect(
        ChatFrames.encode(const TypingFrame(typing: true)),
        '{"t":"typing","typing":true}',
      );
      expect(
        ChatFrames.encode(ReadFrame(ids: [_id(1), _id(2)])),
        '{"t":"read","ids":["${_id(1)}","${_id(2)}"]}',
      );
    });
  });

  group('rejects malformed frames', () {
    void rejects(String raw, String reason) {
      expect(
        () => ChatFrames.decode(raw),
        throwsA(
          isA<ChatFrameException>().having((e) => e.reason, 'reason', reason),
        ),
        reason: raw,
      );
    }

    test('not JSON, or not an object', () {
      rejects('not json', 'malformed');
      rejects('[1,2]', 'malformed');
      rejects('"hello"', 'malformed');
    });

    test('unknown type', () {
      rejects('{"t":"video"}', 'unknown');
      rejects('{}', 'unknown');
    });

    test('another protocol version', () {
      rejects('{"t":"hello","v":2}', 'version');
      rejects('{"t":"hello"}', 'version');
    });

    test('message ids must be 16 random bytes', () {
      rejects('{"t":"ack","id":"short"}', 'malformed');
      rejects('{"t":"ack","id":"${_id(1)}="}', 'malformed');
      rejects('{"t":"ack","id":7}', 'malformed');
      rejects('{"t":"msg","id":"${_id(1)}","ts":0,"text":"x"}', 'malformed');
    });

    test('timestamps must be positive whole numbers', () {
      rejects('{"t":"msg","id":"${_id(1)}","ts":"1","text":"x"}', 'malformed');
      rejects('{"t":"msg","id":"${_id(1)}","ts":1.5,"text":"x"}', 'malformed');
    });

    test('text must be a string of at most 4000 characters', () {
      rejects('{"t":"msg","id":"${_id(1)}","ts":1,"text":5}', 'malformed');
      final long = 'a' * (maxTextChars + 1);
      rejects('{"t":"msg","id":"${_id(1)}","ts":1,"text":"$long"}', 'too-long');
    });

    test('frames over 16 KiB are refused before they are read', () {
      final huge = 'a' * (maxFrameBytes + 1);
      rejects(
        '{"t":"msg","id":"${_id(1)}","ts":1,"text":"$huge"}',
        'too-large',
      );
    });
  });

  test(
    'text of exactly 4000 characters is accepted, even at the frame limit',
    () {
      // Every character a 4-byte emoji: the largest text a frame can carry.
      final text = List.filled(maxTextChars, '\u{1F600}').join();
      final raw = ChatFrames.encode(
        MessageFrame(id: _id(1), ts: 1, text: text),
      );
      final decoded = ChatFrames.decode(raw) as MessageFrame;
      expect(decoded.text.runes.length, maxTextChars);
    },
  );

  test('encoding refuses a frame over 16 KiB', () {
    final text = List.filled(maxTextChars, '\u{1F600}').join() + '"' * 4000;
    expect(
      () => ChatFrames.encode(MessageFrame(id: _id(1), ts: 1, text: text)),
      throwsA(isA<ChatFrameException>()),
    );
  });

  group('cleanText', () {
    test('removes control characters but keeps line breaks and tabs', () {
      expect(
        ChatFrames.cleanText('a\u0000b\u0007c\u007Fd\u0085e\nf\tg'),
        'abcde\nf\tg',
      );
    });

    test('removes characters that change the reading direction', () {
      // Right-to-left override, and a left-to-right isolate.
      expect(ChatFrames.cleanText('pay\u202E 100\u2066'), 'pay 100');
    });

    test('keeps Arabic and Bangla text, and trims the ends', () {
      expect(ChatFrames.cleanText('  مرحبا  '), 'مرحبا');
      expect(ChatFrames.cleanText('ঁ নমস্কার​'), 'ঁ নমস্কার​');
    });
  });

  group('ids', () {
    test('newId makes 16 random bytes, unpadded base64url', () {
      final a = ChatFrames.newId(Random(1));
      final b = ChatFrames.newId(Random(2));
      expect(a.length, 22);
      expect(ChatFrames.isId(a), isTrue);
      expect(a, isNot(b));
      expect(b64Decode(a).length, 16);
    });

    test('isId accepts only the canonical form', () {
      expect(ChatFrames.isId(_id(9)), isTrue);
      expect(ChatFrames.isId(_id(9).substring(1)), isFalse);
      expect(ChatFrames.isId('${_id(9)}='), isFalse);
      expect(ChatFrames.isId(null), isFalse);
      expect(ChatFrames.isId(12), isFalse);
    });
  });

  group('file frames', () {
    test('file frame types encode and decode correctly', () {
      final offer = FileOfferFrame(
        id: _id(10),
        name: 'document.pdf',
        size: 1024,
        mime: 'application/pdf',
        sha256: 'abc123hash',
        chunks: 1,
      );
      final accept = FileAcceptFrame(id: _id(10));
      final decline = FileDeclineFrame(id: _id(10));
      final done = FileDoneFrame(id: _id(10));
      final ack = FileAckFrame(id: _id(10));
      final cancel = FileCancelFrame(id: _id(10), reason: 'user-cancelled');

      final decodedOffer =
          ChatFrames.decode(ChatFrames.encode(offer)) as FileOfferFrame;
      expect(decodedOffer.id, _id(10));
      expect(decodedOffer.name, 'document.pdf');
      expect(decodedOffer.size, 1024);
      expect(decodedOffer.mime, 'application/pdf');
      expect(decodedOffer.sha256, 'abc123hash');
      expect(decodedOffer.chunks, 1);

      final decodedAccept =
          ChatFrames.decode(ChatFrames.encode(accept)) as FileAcceptFrame;
      expect(decodedAccept.id, _id(10));

      final decodedDecline =
          ChatFrames.decode(ChatFrames.encode(decline)) as FileDeclineFrame;
      expect(decodedDecline.id, _id(10));

      final decodedDone =
          ChatFrames.decode(ChatFrames.encode(done)) as FileDoneFrame;
      expect(decodedDone.id, _id(10));

      final decodedAck =
          ChatFrames.decode(ChatFrames.encode(ack)) as FileAckFrame;
      expect(decodedAck.id, _id(10));

      final decodedCancel =
          ChatFrames.decode(ChatFrames.encode(cancel)) as FileCancelFrame;
      expect(decodedCancel.id, _id(10));
      expect(decodedCancel.reason, 'user-cancelled');
    });

    test('rejects file offer with blocked extension or invalid parameters', () {
      expect(
        () => ChatFrames.decode(
          '{"t":"file.offer","id":"${_id(10)}","name":"malware.exe","size":100,"mime":"application/octet-stream","sha256":"hash","chunks":1}',
        ),
        throwsA(isA<ChatFrameException>()),
      );
      expect(
        () => ChatFrames.decode(
          '{"t":"file.offer","id":"${_id(10)}","name":"test.txt","size":0,"mime":"text/plain","sha256":"hash","chunks":1}',
        ),
        throwsA(isA<ChatFrameException>()),
      );
      expect(
        () => ChatFrames.decode(
          '{"t":"file.offer","id":"${_id(10)}","name":"test.txt","size":100,"mime":"text/plain","sha256":"hash","chunks":0}',
        ),
        throwsA(isA<ChatFrameException>()),
      );
    });

    test('encodeChunk and decodeChunk round trip', () {
      final fileId = _id(15);
      final payload = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
      final encoded = ChatFrames.encodeChunk(
        fileId: fileId,
        chunkIndex: 42,
        payload: payload,
      );
      expect(encoded.length, 20 + payload.length);

      final decoded = ChatFrames.decodeChunk(encoded);
      expect(decoded.fileId, fileId);
      expect(decoded.chunkIndex, 42);
      expect(decoded.payload, payload);

      expect(
        () => ChatFrames.decodeChunk(Uint8List(19)),
        throwsA(isA<ChatFrameException>()),
      );
    });
  });

  group('cleanFileName', () {
    test('removes path separators and leading dots', () {
      expect(
        ChatFrames.cleanFileName('../secret/passwords.txt'),
        '_secret_passwords.txt',
      );
      expect(ChatFrames.cleanFileName(r'..\..\config.json'), '__config.json');
      expect(ChatFrames.cleanFileName('...hidden.doc'), 'hidden.doc');
    });

    test('defaults empty or dot-only filenames to "file"', () {
      expect(ChatFrames.cleanFileName(''), 'file');
      expect(ChatFrames.cleanFileName('...'), 'file');
    });

    test('prefixes reserved Windows names with file_', () {
      expect(ChatFrames.cleanFileName('CON.txt'), 'file_CON.txt');
      expect(ChatFrames.cleanFileName('nul'), 'file_nul');
      expect(ChatFrames.cleanFileName('prn.pdf'), 'file_prn.pdf');
      expect(ChatFrames.cleanFileName('COM1.dat'), 'file_COM1.dat');
    });

    test('truncates extremely long names while preserving extension', () {
      final longName = '${'a' * 150}.pdf';
      final cleaned = ChatFrames.cleanFileName(longName);
      expect(cleaned.length, lessThanOrEqualTo(120));
      expect(cleaned.endsWith('.pdf'), isTrue);
    });
  });

  group('isBlockedFileType', () {
    test('identifies executable, script, and installer files', () {
      expect(ChatFrames.isBlockedFileType('virus.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.bat'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.cmd'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.sh'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.ps1'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.vbs'), isTrue);
      expect(ChatFrames.isBlockedFileType('app.apk'), isTrue);
      expect(ChatFrames.isBlockedFileType('installer.msi'), isTrue);
      expect(ChatFrames.isBlockedFileType('setup.dmg'), isTrue);
    });

    test('permits safe documents and media files', () {
      expect(ChatFrames.isBlockedFileType('document.pdf'), isFalse);
      expect(ChatFrames.isBlockedFileType('photo.png'), isFalse);
      expect(ChatFrames.isBlockedFileType('photo.jpg'), isFalse);
      expect(ChatFrames.isBlockedFileType('video.mp4'), isFalse);
      expect(ChatFrames.isBlockedFileType('notes.txt'), isFalse);
      expect(ChatFrames.isBlockedFileType('archive.zip'), isFalse);
    });
  });
}
