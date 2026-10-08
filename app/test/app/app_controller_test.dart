import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/call/call_controller.dart';
import 'package:sotto/call/call_manager.dart';
import 'package:sotto/core/server_address.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/history/call_history.dart';
import 'package:sotto/lock/app_lock.dart';
import 'package:sotto/storage/backup.dart';
import 'package:sotto/storage/vault.dart';
import 'package:sotto/storage/vault_file_io.dart';

import '../call/devices_test.dart' show FakeLister;

void main() {
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp('sotto-app'),
  );
  tearDown(() => directory.delete(recursive: true));

  AppController app(
    MemorySecretStore keystore, {
    String file = 'sotto.vault',
  }) => AppController(
    relayUrl: Uri.parse('ws://localhost:1/relay'),
    linkBase: Uri.parse('http://localhost:1/'),
    persistent: true,
    keystore: keystore,
    openVaultFile: () async => DiskVaultFile('${directory.path}/$file'),
    deviceLister: FakeLister.new,
    startCalls: false,
    formerDefaultHosts: const {'old.sotto.example'},
  );

  test('first start: onboarding, then everything survives a restart', () async {
    final keystore = MemorySecretStore();
    final first = app(keystore);
    await first.start();
    expect(first.stage, AppStage.onboarding);
    expect(first.hasIdentity, isFalse);

    await first.completeOnboarding(
      name: ' Dr Meera Rao ',
      practice: 'Lotus Clinic',
    );
    expect(first.stage, AppStage.ready);
    expect(first.profile!.label, 'Dr Meera Rao (Lotus Clinic)');
    await first.lock.setPin('135790');
    final colleague = Identity.generate(first.sodium).publicIdentity;
    await first.contacts.add(colleague, name: 'Arun', verified: true);

    // The vault file is encrypted; only the key is in the keystore.
    final onDisk = await File('${directory.path}/sotto.vault')
        .readAsString(encoding: latin1);
    expect(onDisk, isNot(contains('Arun')));
    expect(onDisk, isNot(contains('Meera')));
    expect(await keystore.read(Vault.keyName), isNotNull);

    final second = app(keystore);
    await second.start();
    expect(second.stage, AppStage.ready);
    expect(second.profile!.name, 'Dr Meera Rao');
    expect(second.contacts.find(colleague)!.name, 'Arun');
    expect(second.lock.locked, isTrue, reason: 'starts locked with a PIN');
    expect(await second.lock.unlock('135790'), UnlockResult.unlocked);
  });

  test('a custom server is kept, backed up, and can be reset', () async {
    final keystore = MemorySecretStore();
    final first = app(keystore);
    await first.start();
    await first.completeOnboarding(name: 'Dr Rao');
    expect(first.server.label, 'localhost:1');
    expect(first.usesCustomServer, isFalse);

    final own = ServerAddress.parse('sotto.clinic.example');
    await first.setServer(own);
    expect(first.server, own);
    expect(first.stage, AppStage.ready);

    final second = app(keystore);
    await second.start();
    expect(second.server, own);
    expect(second.usesCustomServer, isTrue);

    final backup = await second.exportBackup('a long passphrase');
    final restored = app(MemorySecretStore(), file: 'restored.vault');
    await restored.start();
    await restored.restoreBackup(backup, 'a long passphrase');
    expect(restored.server, own, reason: 'links point to the same server');

    await second.setServer(null);
    expect(second.usesCustomServer, isFalse);
    final third = app(keystore);
    await third.start();
    expect(third.server.label, 'localhost:1');
  });

  test(
    'an earlier built-in server chosen by hand becomes the built-in one',
    () async {
      final keystore = MemorySecretStore();
      final first = app(keystore);
      await first.start();
      await first.completeOnboarding(name: 'Dr Rao');
      await first.setServer(ServerAddress.parse('old.sotto.example'));
      expect(first.usesCustomServer, isTrue);

      final second = app(keystore);
      await second.start();
      expect(second.usesCustomServer, isFalse);
      expect(second.server.label, 'localhost:1');
      final third = app(keystore);
      await third.start();
      expect(third.usesCustomServer, isFalse, reason: 'the choice was removed');
    },
  );

  test(
    'upgrading from Phase 5: keystore settings move into the vault',
    () async {
      final keystore = MemorySecretStore();
      final sodium = await SottoCrypto.init();
      await IdentityStore(sodium, keystore).loadOrCreate();
      await keystore.write(AppController.legacyHostNameKey, 'Dr Rao');
      await keystore.write(CallController.hideIpSetting, '1');

      final upgraded = app(keystore);
      await upgraded.start();
      expect(upgraded.stage, AppStage.onboarding);
      expect(upgraded.hasIdentity, isTrue, reason: 'the identity is kept');
      expect(upgraded.suggestedName, 'Dr Rao');
      expect(await keystore.read(CallController.hideIpSetting), isNull);
      await upgraded.completeOnboarding(name: 'Dr Rao');
      expect(upgraded.stage, AppStage.ready);
    },
  );

  test('backup and restore on another device; erase', () async {
    final keystore = MemorySecretStore();
    final original = app(keystore);
    await original.start();
    await original.completeOnboarding(name: 'Dr Meera Rao');
    await original.lock.setPin('135790');
    final wife = Identity.generate(original.sodium).publicIdentity;
    await original.contacts.add(wife, name: 'Priya', verified: true);
    await original.history.add(
      CallRecord(
        id: 'c1',
        name: 'Priya',
        peer: wife,
        outgoing: true,
        video: false,
        startedAt: DateTime.now().toUtc(),
        endedAt: DateTime.now().toUtc(),
        endReason: CallEndReason.hungUp,
        note: 'private note',
      ),
    );
    final id = (await IdentityStore(original.sodium, keystore).load())!.id;

    final backup = await original.exportBackup('a long passphrase');
    expect(backup, isNot(contains('Priya')));
    final withoutHistory = await original.exportBackup(
      'a long passphrase',
      includeHistory: false,
    );

    // A new device, already set up with its own identity and PIN.
    final otherKeys = MemorySecretStore();
    final other = app(otherKeys, file: 'other.vault');
    await other.start();
    await other.completeOnboarding(name: 'Someone else');
    await other.lock.setPin('000111');
    await expectLater(
      other.restoreBackup(backup, 'wrong passphrase'),
      throwsA(isA<BackupException>()),
    );
    await other.restoreBackup(backup, 'a long passphrase');
    expect(other.stage, AppStage.ready);
    expect((await IdentityStore(other.sodium, otherKeys).load())!.id, id);
    expect(other.profile!.name, 'Dr Meera Rao');
    expect(other.contacts.find(wife)!.verified, isTrue);
    expect(other.history.find('c1')!.note, 'private note');
    // The device's own PIN stays (it was never in the backup).
    expect(await other.lock.check('000111'), UnlockResult.unlocked);

    final third = app(MemorySecretStore(), file: 'third.vault');
    await third.start();
    await third.restoreBackup(withoutHistory, 'a long passphrase');
    expect(third.history.entries, isEmpty);
    expect(third.contacts.find(wife), isNotNull);

    await other.eraseEverything();
    expect(other.stage, AppStage.onboarding);
    expect(other.hasIdentity, isFalse);
    expect(other.contacts.contacts, isEmpty);
  });

  test(
    'without a keystore: a clear error, and a session that saves nothing',
    () async {
      final broken = AppController(
        relayUrl: Uri.parse('ws://localhost:1/relay'),
        linkBase: Uri.parse('http://localhost:1/'),
        persistent: true,
        keystore: _BrokenKeystore(),
        openVaultFile: () async =>
            DiskVaultFile('${directory.path}/never.vault'),
        deviceLister: FakeLister.new,
        startCalls: false,
      );
      await broken.start();
      expect(broken.stage, AppStage.failed);
      expect(broken.keystoreMissing, isTrue);
      expect(broken.error, contains('keystore'));

      await broken.startTemporarySession();
      expect(broken.stage, AppStage.onboarding);
      expect(broken.persistent, isFalse);
      expect(broken.backupsAvailable, isFalse);
      await broken.completeOnboarding(name: 'Dr Rao');
      expect(broken.stage, AppStage.ready);
      expect(File('${directory.path}/never.vault').existsSync(), isFalse);
    },
  );

  test('a vault that cannot be opened is reported, and can be reset', () async {
    final keystore = MemorySecretStore();
    final first = app(keystore);
    await first.start();
    await first.completeOnboarding(name: 'Dr Rao');
    await keystore.delete(Vault.keyName);

    final broken = app(keystore);
    await broken.start();
    expect(broken.stage, AppStage.vaultProblem);
    await broken.resetStorage();
    expect(broken.stage, AppStage.onboarding);
    expect(broken.hasIdentity, isTrue);
  });
}

class _BrokenKeystore implements SecretStore {
  @override
  Future<String?> read(String key) => throw Exception('no secret service');
  @override
  Future<void> write(String key, String value) =>
      throw Exception('no secret service');
  @override
  Future<void> delete(String key) => throw Exception('no secret service');
}
