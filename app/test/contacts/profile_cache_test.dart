import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/contacts/contact_link.dart';
import 'package:sotto/contacts/profile_cache.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late Sodium sodium;

  setUpAll(() async {
    sodium = await SottoCrypto.init();
  });

  ContactInvite invite(String name, [String? organisation]) => ContactInvite(
    identity: Identity.generate(sodium).publicIdentity,
    name: name,
    organisation: organisation,
  );

  test('remembers a lookup across restarts', () async {
    final store = MemorySecretStore();
    final meera = invite('Dr Meera Rao', 'Rao Physiotherapy');
    await ProfileCache(store).remember(meera);

    final found = await ProfileCache(store).lookup(meera.identity.id);
    expect(found?.identity, meera.identity);
    expect(found?.name, 'Dr Meera Rao');
    expect(found?.organisation, 'Rao Physiotherapy');
    expect(await ProfileCache(store).lookup('someone-else'), isNull);
  });

  test('the newest details replace the old ones', () async {
    final cache = ProfileCache(MemorySecretStore());
    final first = invite('Meera');
    await cache.remember(first);
    await cache.remember(
      ContactInvite(identity: first.identity, name: 'Dr Meera Rao'),
    );
    expect((await cache.lookup(first.identity.id))?.name, 'Dr Meera Rao');
  });

  test('keeps at most maxEntries, forgetting the oldest', () async {
    final cache = ProfileCache(MemorySecretStore());
    final oldest = invite('Oldest');
    await cache.remember(oldest);
    for (var i = 0; i < ProfileCache.maxEntries; i++) {
      await cache.remember(invite('Person $i'));
    }
    expect(await cache.lookup(oldest.identity.id), isNull);
  });

  test('an unreadable cache is ignored', () async {
    final store = MemorySecretStore();
    await store.write(ProfileCache.storageKey, 'not json');
    expect(await ProfileCache(store).lookup('x'), isNull);
    final meera = invite('Meera');
    await ProfileCache(store).remember(meera);
    expect(
      (await ProfileCache(store).lookup(meera.identity.id))?.name,
      'Meera',
    );
  });
}
