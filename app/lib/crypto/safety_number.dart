import 'package:sodium/sodium.dart';

import 'encoding.dart';
import 'identity.dart';

/// A 60-digit code that two people compare to confirm nobody is intercepting
/// their calls. Both sides compute the same value.
///
/// `BLAKE2b-512("sotto-safety-v1\0" || lowerKey || higherKey)` over the two
/// Ed25519 keys in byte order; the first 60 bytes become 12 groups of five
/// digits (each 5-byte big-endian chunk modulo 100000).
abstract final class SafetyNumber {
  static String compute(Sodium sodium, PublicIdentity a, PublicIdentity b) {
    final keys = [a.signKey, b.signKey]..sort(_compareBytes);
    final hash = sodium.crypto.genericHash(
      message: concatBytes([domainLabel('sotto-safety-v1'), keys[0], keys[1]]),
      outLen: 64,
    );
    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      var value = 0;
      for (var j = 0; j < 5; j++) {
        value = value * 256 + hash[i * 5 + j];
      }
      groups.add((value % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
