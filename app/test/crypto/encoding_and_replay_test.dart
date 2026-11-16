import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/replay_guard.dart';

void main() {
  group('base64url', () {
    test('round trips without padding', () {
      for (var length = 0; length < 10; length++) {
        final bytes = List.generate(length, (i) => i * 37 % 256);
        final text = b64Encode(bytes);
        expect(text, isNot(contains('=')));
        expect(b64Decode(text), bytes);
      }
    });

    test('rejects padding, the standard alphabet and non-canonical forms', () {
      expect(() => b64Decode('AA=='), throwsFormatException);
      expect(() => b64Decode('a+/b'), throwsFormatException);
      // 'AB' decodes to one byte but its canonical form is 'AA'.
      expect(() => b64Decode('AB'), throwsFormatException);
      expect(() => b64Decode('A'), throwsFormatException);
    });
  });

  group('ReplayGuard', () {
    final start = DateTime.utc(2026);

    test('accepts a key once and forgets it after the ttl', () {
      final guard = ReplayGuard(ttl: const Duration(minutes: 5));
      expect(guard.checkAndRecord('k', start), isTrue);
      expect(
        guard.checkAndRecord('k', start.add(const Duration(minutes: 4))),
        isFalse,
      );
      expect(
        guard.checkAndRecord('k', start.add(const Duration(minutes: 5))),
        isTrue,
      );
    });

    test('refuses new keys when full, and never forgets a live one', () {
      final guard = ReplayGuard(ttl: const Duration(hours: 1), maxEntries: 3);
      for (final key in ['a', 'b', 'c']) {
        expect(guard.checkAndRecord(key, start), isTrue);
      }
      expect(guard.checkAndRecord('d', start), isFalse, reason: 'full');
      // 'a' is still remembered, so a captured message can't be replayed.
      expect(guard.checkAndRecord('a', start), isFalse);
      expect(guard.length, 3);
      // Once they have expired there is room again.
      expect(
        guard.checkAndRecord('d', start.add(const Duration(hours: 1))),
        isTrue,
      );
    });

    test('a clock set back does not make entries expire early or late', () {
      final guard = ReplayGuard(ttl: const Duration(minutes: 5));
      expect(guard.checkAndRecord('k', start), isTrue);
      // The clock reads earlier than the entry's time: it is still remembered.
      expect(
        guard.checkAndRecord('k', start.subtract(const Duration(minutes: 1))),
        isFalse,
      );
      // Five minutes after the latest time seen, it is forgotten.
      expect(
        guard.checkAndRecord('k', start.add(const Duration(minutes: 5))),
        isTrue,
      );
    });
  });
}
