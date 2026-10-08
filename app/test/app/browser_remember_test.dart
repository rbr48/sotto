import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/lock/app_lock.dart';
import 'package:sotto/storage/browser_storage.dart';

import '../call/devices_test.dart' show FakeLister;

/// "Remember me on this browser", with the browser's storage in memory: a
/// new [AppController] on the same storage is a page reload.
void main() {
  AppController browser(MemoryBrowserStorage storage) => AppController(
    relayUrl: Uri.parse('ws://localhost:1/relay'),
    linkBase: Uri.parse('http://localhost:1/'),
    persistent: false,
    browserStorage: storage,
    deviceLister: FakeLister.new,
    startCalls: false,
  );

  Future<String?> storedMaster(MemoryBrowserStorage storage) async =>
      (await storage.open())?.secrets.read(IdentityStore.masterSecretKey);

  test('a browser session keeps nothing unless remembered', () async {
    final storage = MemoryBrowserStorage();
    final first = browser(storage);
    await first.start();
    await first.completeOnboarding(name: 'Dr Rao');
    expect(first.stage, AppStage.ready);
    expect(first.persistent, isFalse);
    expect(first.rememberedInBrowser, isFalse);
    expect(first.canRememberInBrowser, isTrue);
    expect(await storage.open(), isNull);

    final reloaded = browser(storage);
    await reloaded.start();
    expect(reloaded.stage, AppStage.onboarding, reason: 'a new identity');
  });

  test(
    'Remember me keeps the identity, contacts and PIN across reloads',
    () async {
      final storage = MemoryBrowserStorage();
      final first = browser(storage);
      await first.start();
      await first.completeOnboarding(
        name: 'Dr Rao',
        practice: 'Lotus Clinic',
        rememberInBrowser: true,
      );
      expect(first.stage, AppStage.ready);
      expect(first.rememberedInBrowser, isTrue);
      expect(first.persistent, isTrue);
      expect(first.canChangeServer, isFalse, reason: 'the page sets it');
      await first.lock.setPin('135790');
      final colleague = Identity.generate(first.sodium).publicIdentity;
      await first.contacts.add(colleague, name: 'Arun', verified: true);
      final master = await storedMaster(storage);
      expect(master, isNotNull);

      final reloaded = browser(storage);
      await reloaded.start();
      expect(reloaded.stage, AppStage.ready);
      expect(reloaded.rememberedInBrowser, isTrue);
      expect(reloaded.profile!.label, 'Dr Rao (Lotus Clinic)');
      expect(reloaded.contacts.find(colleague)!.name, 'Arun');
      expect(await storedMaster(storage), master, reason: 'same identity');
      expect(reloaded.lock.locked, isTrue);
      expect(await reloaded.lock.unlock('000000'), UnlockResult.wrongPin);
      expect(
        await reloaded.lock.unlock('135790'),
        UnlockResult.unlocked,
        reason: "the PIN hash's key is kept with the identity",
      );
    },
  );

  test(
    'turning it on later keeps the session; forgetting deletes it',
    () async {
      final storage = MemoryBrowserStorage();
      final app = browser(storage);
      await app.start();
      await app.completeOnboarding(name: 'Dr Rao');
      await app.lock.setPin('246801');
      final colleague = Identity.generate(app.sodium).publicIdentity;
      await app.contacts.add(colleague, name: 'Arun');

      await app.rememberInBrowser();
      expect(app.stage, AppStage.ready);
      expect(app.rememberedInBrowser, isTrue);
      expect(app.contacts.find(colleague)!.name, 'Arun');
      expect(await app.lock.unlock('246801'), UnlockResult.unlocked);
      final master = await storedMaster(storage);
      expect(master, isNotNull);

      final reloaded = browser(storage);
      await reloaded.start();
      expect(reloaded.contacts.find(colleague)!.name, 'Arun');
      expect(await storedMaster(storage), master);

      await reloaded.forgetBrowser();
      expect(reloaded.stage, AppStage.ready, reason: 'this tab keeps working');
      expect(reloaded.rememberedInBrowser, isFalse);
      expect(reloaded.persistent, isFalse);
      expect(reloaded.contacts.find(colleague)!.name, 'Arun');
      expect(await storage.open(), isNull, reason: 'deleted from the browser');

      final afterForgetting = browser(storage);
      await afterForgetting.start();
      expect(afterForgetting.stage, AppStage.onboarding);
    },
  );

  test('erasing a remembered identity clears the browser storage', () async {
    final storage = MemoryBrowserStorage();
    final app = browser(storage);
    await app.start();
    await app.completeOnboarding(name: 'Dr Rao', rememberInBrowser: true);
    await app.eraseEverything();
    expect(app.stage, AppStage.onboarding);
    expect(app.rememberedInBrowser, isFalse);
    expect(await storage.open(), isNull);
  });
}
