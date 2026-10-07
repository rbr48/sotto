import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/storage/vault.dart';
import 'package:sotto/storage/vault_file.dart';
import 'package:sotto/storage/vault_file_io.dart';

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  test(
    'stores values encrypted and reopens them with the keystore key',
    () async {
      final keys = MemorySecretStore();
      final file = MemoryVaultFile();
      final vault = await Vault.open(sodium: sodium, keys: keys, file: file);
      await vault.write('sotto.contacts.v1', 'Priya, the client notes');
      await vault.flush();

      expect(await keys.read(Vault.keyName), isNotNull);
      final onDisk = String.fromCharCodes(file.bytes!);
      expect(onDisk, startsWith('SOTTOVAULT1'));
      expect(onDisk, isNot(contains('Priya')));

      final reopened = await Vault.open(sodium: sodium, keys: keys, file: file);
      expect(
        await reopened.read('sotto.contacts.v1'),
        'Priya, the client notes',
      );
      await reopened.delete('sotto.contacts.v1');
      final again = await Vault.open(sodium: sodium, keys: keys, file: file);
      expect(await again.read('sotto.contacts.v1'), isNull);
    },
  );

  test(
    'refuses a vault whose key is missing, wrong or tampered with',
    () async {
      final keys = MemorySecretStore();
      final file = MemoryVaultFile();
      final vault = await Vault.open(sodium: sodium, keys: keys, file: file);
      await vault.write('a', 'b');
      await vault.flush();

      await expectLater(
        Vault.open(sodium: sodium, keys: MemorySecretStore(), file: file),
        throwsA(isA<VaultException>()),
      );

      final otherKeys = MemorySecretStore();
      await Vault.open(
        sodium: sodium,
        keys: otherKeys,
        file: MemoryVaultFile(),
      );
      await expectLater(
        Vault.open(sodium: sodium, keys: otherKeys, file: file),
        throwsA(isA<VaultException>()),
      );

      final tampered = Uint8List.fromList(file.bytes!);
      tampered[tampered.length - 1] ^= 1;
      await expectLater(
        Vault.open(
          sodium: sodium,
          keys: keys,
          file: MemoryVaultFile()..bytes = tampered,
        ),
        throwsA(isA<VaultException>()),
      );

      await expectLater(
        Vault.open(
          sodium: sodium,
          keys: keys,
          file: MemoryVaultFile()..bytes = Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<VaultException>()),
      );
    },
  );

  test('every save uses a fresh nonce', () async {
    final file = MemoryVaultFile();
    final vault = await Vault.open(
      sodium: sodium,
      keys: MemorySecretStore(),
      file: file,
    );
    await vault.write('a', 'same');
    final first = file.bytes!;
    await vault.write('a', 'same');
    expect(file.bytes, isNot(equals(first)));
  });

  test('moves settings out of the old keystore entries', () async {
    final old = MemorySecretStore();
    await old.write('sotto.settings.hide_ip', '1');
    await old.write('sotto.guest_links.v1', '[]');
    final vault = await Vault.open(
      sodium: sodium,
      keys: MemorySecretStore(),
      file: MemoryVaultFile(),
    );
    await vault.write('sotto.guest_links.v1', '[{"kept":true}]');
    await vault.migrateFrom(old, [
      'sotto.settings.hide_ip',
      'sotto.guest_links.v1',
      'missing',
    ]);
    expect(await vault.read('sotto.settings.hide_ip'), '1');
    expect(await vault.read('sotto.guest_links.v1'), '[{"kept":true}]');
    expect(await old.read('sotto.settings.hide_ip'), isNull);
    expect(await old.read('sotto.guest_links.v1'), isNull);
  });

  test('a disk vault is replaced atomically and can be erased', () async {
    final directory = await Directory.systemTemp.createTemp('sotto-vault');
    addTearDown(() => directory.delete(recursive: true));
    final keys = MemorySecretStore();
    final file = DiskVaultFile('${directory.path}/sotto.vault');
    final vault = await Vault.open(sodium: sodium, keys: keys, file: file);
    await vault.write('note', 'secret');
    expect(File('${directory.path}/sotto.vault.tmp').existsSync(), isFalse);
    final reopened = await Vault.open(sodium: sodium, keys: keys, file: file);
    expect(await reopened.read('note'), 'secret');

    await Vault.erase(keys: keys, file: file);
    expect(File(file.path).existsSync(), isFalse);
    expect(await keys.read(Vault.keyName), isNull);
  });
}
