import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/call/call_code.dart';
import 'package:sotto/contacts/contact_book.dart';
import 'package:sotto/contacts/contact_link.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  PublicIdentity person() => Identity.generate(sodium).publicIdentity;

  group('auto-answer rules', () {
    test(
      'off by default; only verified contacts chosen for auto-answer',
      () async {
        final book = ContactBook(MemorySecretStore());
        final wife = person();
        await book.add(wife, name: 'Priya', verified: true);
        await book.update(book.find(wife)!.copyWith(autoAnswer: true));
        expect(book.autoAnswerEnabled, isFalse);
        expect(book.decide(wife, videoCall: true), isNull);

        await book.setAutoAnswerEnabled(true);
        final voice = book.decide(wife, videoCall: true)!;
        expect(
          voice.delay,
          const Duration(seconds: ContactBook.defaultDelaySeconds),
        );
        expect(voice.video, isFalse);

        await book.update(book.find(wife)!.copyWith(autoAnswerVideo: true));
        await book.setDelaySeconds(2);
        final video = book.decide(wife, videoCall: true)!;
        expect(video.video, isTrue);
        expect(video.delay, const Duration(seconds: 2));
        expect(book.decide(wife, videoCall: false)!.video, isFalse);
        expect(book.trusted.map((c) => c.name), ['Priya']);
      },
    );

    test('unverified contacts and strangers always ring', () async {
      final book = ContactBook(MemorySecretStore());
      await book.setAutoAnswerEnabled(true);
      final colleague = person();
      await book.add(colleague, name: 'Arun');
      await book.update(book.find(colleague)!.copyWith(autoAnswer: true));
      expect(
        book.find(colleague)!.autoAnswer,
        isFalse,
        reason: 'auto-answer needs a verified contact',
      );
      expect(book.decide(colleague, videoCall: true), isNull);
      expect(book.decide(person(), videoCall: true), isNull);

      final wife = person();
      await book.add(wife, name: 'Priya', verified: true);
      await book.update(book.find(wife)!.copyWith(autoAnswer: true));
      final sameSignKey = PublicIdentity(
        signKey: wife.signKey,
        boxKey: person().boxKey,
      );
      expect(book.decide(sameSignKey, videoCall: true), isNull);

      // Un-verifying turns auto-answer off for that person.
      await book.update(book.find(wife)!.copyWith(verified: false));
      expect(book.decide(wife, videoCall: true), isNull);
    });

    test('delay limits and removal', () async {
      final book = ContactBook(MemorySecretStore());
      final wife = person();
      await book.add(wife, name: 'Priya', verified: true);
      await book.update(book.find(wife)!.copyWith(autoAnswer: true));
      await book.setAutoAnswerEnabled(true);
      await book.setDelaySeconds(99);
      expect(book.delaySeconds, ContactBook.maxDelaySeconds);
      await book.setDelaySeconds(-3);
      expect(book.delaySeconds, 0);
      await book.remove(wife);
      expect(book.decide(wife, videoCall: true), isNull);
      expect(book.contacts, isEmpty);
    });
  });

  test(
    're-adding keeps verification and auto-answer; contacts sort by name',
    () async {
      final store = MemorySecretStore();
      final book = ContactBook(store);
      final wife = person();
      await book.add(wife, name: 'Priya', verified: true);
      await book.update(book.find(wife)!.copyWith(autoAnswer: true));
      await book.add(wife, name: 'Priya S', organisation: 'Home');
      expect(book.find(wife)!.verified, isTrue);
      expect(book.find(wife)!.autoAnswer, isTrue);
      expect(book.find(wife)!.label, 'Priya S (Home)');
      await book.add(person(), name: 'arun');
      expect(book.contacts.map((c) => c.name), ['arun', 'Priya S']);

      final reloaded = ContactBook(store);
      await reloaded.load();
      expect(reloaded.contacts.map((c) => c.name), ['arun', 'Priya S']);
      expect(reloaded.find(wife)!.autoAnswer, isTrue);

      await store.write(ContactBook.storageKey, '{broken');
      final broken = ContactBook(store);
      await broken.load();
      expect(broken.autoAnswerEnabled, isFalse);
    },
  );

  test(
    'Phase 5B trusted callers become verified contacts with auto-answer',
    () async {
      final store = MemorySecretStore();
      final wife = person();
      await store.write(
        ContactBook.legacyTrustedKey,
        jsonEncode({
          'enabled': true,
          'delay': 3,
          'callers': [
            {
              'sign': b64Encode(wife.signKey),
              'box': b64Encode(wife.boxKey),
              'name': 'Priya',
              'video': true,
            },
          ],
        }),
      );
      final book = ContactBook(store);
      await book.load();
      expect(book.autoAnswerEnabled, isTrue);
      expect(book.delaySeconds, 3);
      final contact = book.find(wife)!;
      expect(
        contact.verified && contact.autoAnswer && contact.autoAnswerVideo,
        isTrue,
      );
      expect(await store.read(ContactBook.legacyTrustedKey), isNull);
      expect(book.decide(wife, videoCall: true)?.video, isTrue);
    },
  );

  group('contact links', () {
    final base = Uri.parse('https://sotto.example/');

    test('round trip with name and organisation; never in the query', () {
      final me = Identity.generate(sodium);
      final link = ContactLink.create(
        sodium,
        me,
        base: base,
        name: ' Dr Rao ',
        organisation: 'Clinic',
      );
      expect(link, startsWith('https://sotto.example/#c='));
      expect(Uri.parse(link).query, isEmpty);
      expect(ContactLink.isContactLink(link), isTrue);
      final invite = ContactLink.parse(sodium, '  $link ');
      expect(invite.identity, me.publicIdentity);
      expect(invite.name, 'Dr Rao');
      expect(invite.organisation, 'Clinic');

      final noOrg = ContactLink.parse(
        sodium,
        ContactLink.create(
          sodium,
          me,
          base: base,
          name: 'Dr Rao',
          organisation: ' ',
        ),
      );
      expect(noOrg.organisation, isNull);
    });

    test('call links and codes are accepted without a name', () {
      final me = Identity.generate(sodium);
      final card = me.card(sodium);
      for (final input in [CallCode.link(base, card), CallCode.encode(card)]) {
        final invite = ContactLink.parse(sodium, input);
        expect(invite.identity, me.publicIdentity);
        expect(invite.name, isNull);
      }
    });

    test('an altered name or a foreign signature is rejected', () {
      final me = Identity.generate(sodium);
      final link = ContactLink.create(sodium, me, base: base, name: 'Dr Rao');
      final payload = link.split('#c=')[1];
      final json =
          jsonDecode(utf8.decode(b64Decode(payload))) as Map<String, dynamic>;
      String encode(Map<String, dynamic> j) =>
          'https://sotto.example/#c=${b64Encode(utf8.encode(jsonEncode(j)))}';

      expect(
        () => ContactLink.parse(sodium, encode({...json, 'n': 'Dr Evil'})),
        throwsA(isA<InvalidIdentityException>()),
      );
      final other = Identity.generate(sodium);
      expect(
        () => ContactLink.parse(
          sodium,
          encode({...json, 'card': other.card(sodium).toJson()}),
        ),
        throwsA(isA<InvalidIdentityException>()),
      );
      for (final bad in ['https://x/#c=', 'https://x/#c=abc', 'hello', '']) {
        expect(
          () => ContactLink.parse(sodium, bad),
          throwsA(isA<InvalidIdentityException>()),
          reason: bad,
        );
      }
    });
  });

  group('pictures', () {
    const good =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAA'
        'AADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    const bad = 'data:image/gif;base64,R0lGODlhAQABAAAAACw=';

    test('only checked pictures are kept, when added, set or loaded', () async {
      final store = MemorySecretStore();
      final book = ContactBook(store);
      final meera = person();
      final arun = person();
      await book.add(meera, name: 'Meera', avatar: bad);
      expect(book.find(meera)!.avatar, isNull);
      await book.setAvatar(meera, good);
      expect(book.find(meera)!.avatar, good);
      await book.setAvatar(meera, bad);
      expect(book.find(meera)!.avatar, isNull);
      await book.add(arun, name: 'Arun', avatar: good);

      // A picture stored by an earlier version that fails the checks.
      final json = jsonDecode(
        (await store.read(ContactBook.storageKey))!,
      ) as Map<String, dynamic>;
      final contacts = json['contacts'] as List<dynamic>;
      for (final c in contacts.cast<Map<String, dynamic>>()) {
        if (c['name'] == 'Meera') c['avatar'] = bad;
      }
      await store.write(ContactBook.storageKey, jsonEncode(json));
      final reloaded = ContactBook(store);
      await reloaded.load();
      expect(reloaded.find(meera)!.avatar, isNull);
      expect(reloaded.find(arun)!.avatar, good);
    });
  });
}
