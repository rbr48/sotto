import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/lock/app_lock.dart';

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  test('PIN rules', () {
    expect(AppLock.isValidPin('123456'), isTrue);
    expect(AppLock.isValidPin('12345'), isFalse);
    expect(AppLock.isValidPin('12345a'), isFalse);
    expect(AppLock.isValidPin('1' * 17), isFalse);
  });

  test('Argon2id verifier: stored hash never contains the PIN', () async {
    final store = MemorySecretStore();
    final lock = AppLock(
      store,
      Argon2PinHasher(SottoCrypto.passwordHashing(sodium)!),
    );
    await lock.load();
    expect(lock.hasPin, isFalse);
    expect(lock.locked, isFalse);
    await lock.setPin('482913');
    expect(await store.read(AppLock.storageKey), contains(r'$argon2id$'));
    expect(await store.read(AppLock.storageKey), isNot(contains('482913')));

    final restarted = AppLock(
      store,
      Argon2PinHasher(SottoCrypto.passwordHashing(sodium)!),
    );
    await restarted.load();
    expect(restarted.locked, isTrue, reason: 'starts locked when a PIN is set');
    expect(await restarted.unlock('000000'), UnlockResult.wrongPin);
    expect(restarted.locked, isTrue);
    expect(await restarted.unlock('482913'), UnlockResult.unlocked);
    expect(restarted.locked, isFalse);
  });

  test(
    'wrong PINs: free attempts, then growing waits that survive restarts',
    () async {
      var now = DateTime(2026, 10, 7, 12);
      final store = MemorySecretStore();
      AppLock make() =>
          AppLock(store, SessionPinHasher(sodium), clock: () => now);
      final lock = make();
      await lock.load();
      await lock.setPin('111111');
      lock.lock();

      for (var i = 1; i < AppLock.freeAttempts; i++) {
        expect(await lock.unlock('999999'), UnlockResult.wrongPin);
      }
      expect(await lock.unlock('999999'), UnlockResult.tooManyAttempts);
      expect(lock.retryIn, AppLock.firstDelay);
      // Even the right PIN must wait.
      expect(await lock.unlock('111111'), UnlockResult.tooManyAttempts);

      now = now.add(AppLock.firstDelay);
      expect(await lock.unlock('999999'), UnlockResult.tooManyAttempts);
      expect(lock.retryIn, AppLock.firstDelay * 2);

      // The count is stored (a restart with the same hasher keeps it).
      final hasher = SessionPinHasher(sodium);
      final fresh = AppLock(store, hasher, clock: () => now);
      await fresh.load();
      expect(fresh.retryIn, AppLock.firstDelay * 2);

      now = now.add(const Duration(hours: 2));
      expect(await lock.unlock('111111'), UnlockResult.unlocked);
      expect(lock.retryIn, Duration.zero);
      expect(await lock.unlock('999999'), UnlockResult.wrongPin);
    },
  );

  test(
    'a PIN set in the browser before Argon2id is stored again on unlock',
    () async {
      final store = MemorySecretStore();
      final legacy = SessionPinHasher(sodium);
      final before = AppLock(store, legacy);
      await before.load();
      await before.setPin('482913');
      expect(await store.read(AppLock.storageKey), contains('session:'));

      final argon = Argon2PinHasher(SottoCrypto.passwordHashing(sodium)!);
      AppLock after() => AppLock(store, MigratingPinHasher(argon, legacy));
      final lock = after();
      await lock.load();
      expect(await lock.unlock('000000'), UnlockResult.wrongPin);
      expect(
        await store.read(AppLock.storageKey),
        contains('session:'),
        reason: 'a wrong PIN changes nothing',
      );

      expect(await lock.unlock('482913'), UnlockResult.unlocked);
      final stored = await store.read(AppLock.storageKey);
      expect(stored, contains(r'$argon2id$'));
      expect(stored, isNot(contains('session:')));

      final again = after();
      await again.load();
      expect(await again.unlock('482913'), UnlockResult.unlocked);
    },
  );

  test('auto-lock after leaving the app for the chosen time', () async {
    var now = DateTime(2026, 10, 7, 12);
    final lock = AppLock(
      MemorySecretStore(),
      SessionPinHasher(sodium),
      clock: () => now,
    );
    await lock.load();
    lock.left();
    lock.returned();
    expect(lock.locked, isFalse, reason: 'no PIN, no lock');

    await lock.setPin('123456');
    await lock.setAutoLockSeconds(60);
    lock.left();
    now = now.add(const Duration(seconds: 59));
    lock.returned();
    expect(lock.locked, isFalse);
    lock.left();
    now = now.add(const Duration(seconds: 60));
    lock.returned();
    expect(lock.locked, isTrue);

    expect(await lock.unlock('123456'), UnlockResult.unlocked);
    await lock.removePin();
    lock.lock();
    expect(lock.locked, isFalse);
  });
}
