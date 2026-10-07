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
}

/// Argon2id (`crypto_pwhash_str`), used by the native apps.
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
    if (!hash.startsWith(r'$argon2')) return false;
    return _sodium.crypto.pwhash.strVerify(passwordHash: hash, password: pin);
  }
}

/// For the browser, where nothing is stored and Argon2id isn't available: a
/// keyed BLAKE2b hash under a key that exists only for this page load.
class SessionPinHasher implements PinHasher {
  SessionPinHasher(this._sodium) : _key = _sodium.crypto.genericHash.keygen();

  final Sodium _sodium;
  final SecureKey _key;

  @override
  String hash(String pin) =>
      'session:${b64Encode(_sodium.crypto.genericHash(message: utf8.encode(pin), key: _key))}';

  @override
  bool verify(String hash, String pin) => hash == this.hash(pin);
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
  int _failures = 0;
  DateTime? _retryAt;
  int _autoLockSeconds = defaultAutoLockSeconds;
  DateTime? _leftAt;

  bool get hasPin => _hash != null;

  /// Whether the app's screens are hidden behind the lock.
  bool get locked => _locked;

  int get autoLockSeconds => _autoLockSeconds;

  /// How long until another PIN may be tried (zero if now).
  Duration get retryIn {
    final retryAt = _retryAt;
    if (retryAt == null) return Duration.zero;
    final left = retryAt.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  static bool isValidPin(String pin) =>
      pin.length >= minPinLength &&
      pin.length <= maxPinLength &&
      RegExp(r'^[0-9]+$').hasMatch(pin);

  /// Loads the lock; the app starts locked if a PIN is set.
  Future<void> load() async {
    final stored = await _store.read(storageKey);
    if (stored != null) {
      try {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        _hash = json['hash'] as String?;
        _failures = json['failures'] as int? ?? 0;
        final retryAt = json['retryAt'] as int?;
        _retryAt = retryAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(retryAt);
        _autoLockSeconds = json['autoLock'] as int? ?? defaultAutoLockSeconds;
      } catch (_) {
        // Unreadable: keep whatever we have; never silently drop a PIN.
      }
    }
    _locked = hasPin;
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await _store.write(
      storageKey,
      jsonEncode({
        'hash': _hash,
        'failures': _failures,
        'retryAt': _retryAt?.millisecondsSinceEpoch,
        'autoLock': _autoLockSeconds,
      }),
    );
  }

  /// Sets or replaces the PIN. Callers must have checked the old PIN.
  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) throw ArgumentError('PIN must be 6–16 digits');
    _hash = _hasher.hash(pin);
    _failures = 0;
    _retryAt = null;
    _locked = false;
    await _save();
  }

  /// Removes the PIN. Callers must have checked it.
  Future<void> removePin() async {
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
    final hash = _hash;
    if (hash == null) return UnlockResult.unlocked;
    if (retryIn > Duration.zero) return UnlockResult.tooManyAttempts;
    if (_hasher.verify(hash, pin)) {
      if (_failures != 0 || _retryAt != null) {
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
      _retryAt = _clock().add(delay > maxDelay ? maxDelay : delay);
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
  void left() => _leftAt = _clock();

  /// The app came back: lock if it was away for the auto-lock time.
  void returned() {
    final leftAt = _leftAt;
    _leftAt = null;
    if (leftAt == null) return;
    if (_clock().difference(leftAt).inSeconds >= _autoLockSeconds) lock();
  }
}
