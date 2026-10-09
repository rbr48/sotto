import 'dart:math';

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
    });

    test('the encoding is the documented JSON', () {
      expect(ChatFrames.encode(const HelloFrame()), '{"t":"hello","v":1}');
      expect(ChatFrames.encode(const ByeFrame()), '{"t":"bye"}');
      expect(
        ChatFrames.encode(AckFrame(id: _id(3))),
        '{"t":"ack","id":"${_id(3)}"}',
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
}
