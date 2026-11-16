import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium_sumo.dart';

import '../crypto/encoding.dart';
import '../crypto/identity_store.dart';

/// Turns a PIN into a stored verifier and checks it.
abstract interface class PinHasher {
  String hash(String pin);
  bool verify(String hash, String pin);

  /// Whether [hash] is in this hasher's current format. A PIN that checks out
  /// against an older format is stored again in the current one.
  bool isCurrent(String hash);
}

/// Argon2id (`crypto_pwhash_str`): the PIN verifier of the app, on every
/// platform.
class Argon2PinHasher implements PinHasher {
  Argon2PinHasher(this._sodium);

  final SodiumSumo _sodium;

  @override
  String hash(String pin) => _sodium.crypto.pwhash.str(
    password: pin,
    opsLimit: _sodium.crypto.pwhash.opsLimitInteractive,
    memLimit: _sodium.crypto.pwhash.memLimitInteractive,
  );

  @override
  bool verify(String hash, String pin) {
    if (!isCurrent(hash)) return false;
    return _sodium.crypto.pwhash.strVerify(passwordHash: hash, password: pin);
  }

  @override
  bool isCurrent(String hash) => hash.startsWith(r'$argon2');
}

/// The browser's PIN verifier before Argon2id was available there: a keyed
/// BLAKE2b hash, kept only so that a PIN set then still works. The key is
/// kept with the identity's secrets, so the PIN works after reloading.
/// [MigratingPinHasher] stores the PIN again in the current format on its
/// next successful check.
class SessionPinHasher implements PinHasher {
  SessionPinHasher(this._sodium, {Uint8List? key})
    : _key = key == null
          ? _sodium.crypto.genericHash.keygen()
          : SecureKey.fromList(_sodium, key);

  final Sodium _sodium;
  final SecureKey _key;

  @override
  String hash(String pin) =>
      'session:${b64Encode(_sodium.crypto.genericHash(message: utf8.encode(pin), key: _key))}';

  @override
  bool verify(String hash, String pin) => hash == this.hash(pin);

  @override
  bool isCurrent(String hash) => false;
}

/// Argon2id for new PINs, and the older browser format for PINs set before
/// the browser had Argon2id. Checks either; never stores the old format.
class MigratingPinHasher implements PinHasher {
  MigratingPinHasher(this._current, this._legacy);

  final Argon2PinHasher _current;
  final SessionPinHasher _legacy;

  @override
  String hash(String pin) => _current.hash(pin);

  @override
  bool verify(String hash, String pin) => _current.isCurrent(hash)
      ? _current.verify(hash, pin)
      : _legacy.verify(hash, pin);

  @override
  bool isCurrent(String hash) => _current.isCurrent(hash);
}

/// The stored lock record, read in full or not at all.
class _LockRecord {
  const _LockRecord({
    required this.hash,
    required this.failures,
    required this.retryAt,
    required this.autoLock,
    required this.seen,
  });

  final String? hash;
  final int failures;
  final DateTime? retryAt;
  final int autoLock;
  final DateTime? seen;
}

enum UnlockResult {
  unlocked,
  wrongPin,

  /// Too many wrong PINs: wait [AppLock.retryIn].
  tooManyAttempts,
}

/// The app lock: a PIN that guards the app's screens and sensitive
/// settings (auto-answer, backups).
///
/// Incoming calls still ring while the app is locked, like a phone; the
/// lock hides contacts, history, notes, links and settings. The data itself
/// is encrypted at rest by the vault.
///
/// After [freeAttempts] wrong PINs, each further attempt must wait, starting
/// at 30 s and doubling up to an hour. The count survives restarts.
class AppLock extends ChangeNotifier {
  AppLock(this._store, this._hasher, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const String storageKey = 'sotto.lock.v1';
  static const int minPinLength = 6;
  static const int maxPinLength = 16;
  static const int freeAttempts = 5;
  static const Duration firstDelay = Duration(seconds: 30);
  static const Duration maxDelay = Duration(hours: 1);

  /// Choices for "lock after leaving the app" (seconds; 0 = immediately).
  static const List<int> autoLockChoices = [0, 60, 300, 900];
  static const int defaultAutoLockSeconds = 60;

  final SecretStore _store;
  final PinHasher _hasher;
  final DateTime Function() _clock;

  String? _hash;
  bool _locked = false;
  bool _damaged = false;
  int _failures = 0;
  DateTime? _retryAt;
  int _autoLockSeconds = defaultAutoLockSeconds;
  DateTime? _leftAt;

  /// The latest time this lock has seen, saved with its record. A clock that
  /// reads earlier than this (the device's time was set back) is taken as this
  /// time, so setting the clock back can't end a wait or unlock the app.
  DateTime? _seen;

  bool get hasPin => _hash != null;

  /// Whether the app's screens are hidden behind the lock.
  bool get locked => _locked;

  /// The stored lock record can't be read, so the PIN can't be checked. The
  /// app stays locked until the device's data is erased (see [load]).
  bool get damaged => _damaged;

  int get autoLockSeconds => _autoLockSeconds;

  /// The current time, never earlier than the latest time seen (see [_seen]).
  DateTime _now() {
    final now = _clock();
    final seen = _seen;
    if (seen != null && now.isBefore(seen)) return seen;
    return _seen = now;
  }

  /// How long until another PIN may be tried (zero if now).
  Duration get retryIn {
    final retryAt = _retryAt;
    if (retryAt == null) return Duration.zero;
    final left = retryAt.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  static bool isValidPin(String pin) =>
      pin.length >= minPinLength &&
      pin.length <= maxPinLength &&
      RegExp(r'^[0-9]+$').hasMatch(pin);

  /// Loads the lock; the app starts locked if a PIN is set.
  ///
  /// A record that can't be read is never overwritten. The PIN can't be
  /// checked, so the app stays locked ([damaged]) until the device's data is
  /// erased. Starting unlocked would drop the PIN, and the next save would
  /// delete it for good.
  Future<void> load() async {
    final stored = await _store.read(storageKey);
    if (stored != null) {
      final record = _parse(stored);
      if (record == null) {
        _damaged = true;
      } else {
        _hash = record.hash;
        _failures = record.failures;
        _retryAt = record.retryAt;
        _autoLockSeconds = record.autoLock;
        _seen = record.seen;
      }
    }
    _locked = hasPin || _damaged;
    notifyListeners();
  }

  /// The record, or null when it can't be read in full.
  static _LockRecord? _parse(String stored) {
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      final retryAt = json['retryAt'] as int?;
      final seen = json['seen'] as int?;
      return _LockRecord(
        hash: json['hash'] as String?,
        failures: json['failures'] as int? ?? 0,
        retryAt: retryAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(retryAt),
        autoLock: json['autoLock'] as int? ?? defaultAutoLockSeconds,
        seen: seen == null ? null : DateTime.fromMillisecondsSinceEpoch(seen),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    notifyListeners();
    // A damaged record stays as it is, for the user to erase.
    if (_damaged) return;
    await _store.write(
      storageKey,
      jsonEncode({
        'hash': _hash,
        'failures': _failures,
        'retryAt': _retryAt?.millisecondsSinceEpoch,
        'autoLock': _autoLockSeconds,
        'seen': _seen?.millisecondsSinceEpoch,
      }),
    );
  }

  /// Sets or replaces the PIN. Callers must have checked the old PIN.
  Future<void> setPin(String pin) async {
    if (_damaged) throw StateError('the app lock record is damaged');
    if (!isValidPin(pin)) throw ArgumentError('PIN must be 6–16 digits');
    _hash = _hasher.hash(pin);
    _failures = 0;
    _retryAt = null;
    _locked = false;
    await _save();
  }

  /// Removes the PIN. Callers must have checked it.
  Future<void> removePin() async {
    if (_damaged) throw StateError('the app lock record is damaged');
    _hash = null;
    _failures = 0;
    _retryAt = null;
    _locked = false;
    await _save();
  }

  Future<void> setAutoLockSeconds(int seconds) async {
    _autoLockSeconds = seconds;
    await _save();
  }

  /// Checks [pin], counting failures. Unlocks the app on success.
  Future<UnlockResult> unlock(String pin) async {
    final result = await check(pin);
    if (result == UnlockResult.unlocked) {
      _locked = false;
      notifyListeners();
    }
    return result;
  }

  /// Checks [pin] (e.g. to confirm a sensitive change), counting failures.
  Future<UnlockResult> check(String pin) async {
    if (_damaged) return UnlockResult.wrongPin;
    final hash = _hash;
    if (hash == null) return UnlockResult.unlocked;
    if (retryIn > Duration.zero) return UnlockResult.tooManyAttempts;
    if (_hasher.verify(hash, pin)) {
      final upgrade = !_hasher.isCurrent(hash);
      if (upgrade) _hash = _hasher.hash(pin);
      if (upgrade || _failures != 0 || _retryAt != null) {
        _failures = 0;
        _retryAt = null;
        await _save();
      }
      return UnlockResult.unlocked;
    }
    _failures++;
    if (_failures >= freeAttempts) {
      final doublings = min(_failures - freeAttempts, 7);
      final delay = firstDelay * (1 << doublings);
      _retryAt = _now().add(delay > maxDelay ? maxDelay : delay);
    }
    await _save();
    return retryIn > Duration.zero
        ? UnlockResult.tooManyAttempts
        : UnlockResult.wrongPin;
  }

  /// Locks now (if a PIN is set).
  void lock() {
    if (!hasPin || _locked) return;
    _locked = true;
    notifyListeners();
  }

  /// The app went to the background.
  void left() => _leftAt = _now();

  /// The app came back: lock if it was away for the auto-lock time.
  void returned() {
    final leftAt = _leftAt;
    _leftAt = null;
    if (leftAt == null) return;
    // A clock that went back while the app was away fails closed: lock.
    if (_clock().isBefore(leftAt) ||
        _now().difference(leftAt).inSeconds >= _autoLockSeconds) {
      lock();
    }
  }
}
