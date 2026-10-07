import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/guest/guest_host.dart';
import 'package:sotto/guest/guest_link.dart';
import 'package:sotto/guest/guest_visit.dart';

OpenedMessage msg(
  PublicIdentity from,
  String type,
  Map<String, dynamic> body,
) =>
    OpenedMessage(sender: from, type: type, body: body, sentAt: DateTime.now());

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  group('GuestLink', () {
    test('a signed link round-trips and reveals the host and name', () {
      final host = Identity.generate(sodium);
      final payload = GuestLink.sign(
        sodium,
        host,
        linkId: 'L1',
        secret: 'S1',
        hostName: 'Dr. Rao',
      );
      final url = GuestLink.url(Uri.parse('https://sotto.example/'), payload);
      expect(url, startsWith('https://sotto.example/#g='));
      final link = GuestLink.parse(sodium, GuestLink.payloadOf(url));
      expect(link.host, host.publicIdentity);
      expect(link.linkId, 'L1');
      expect(link.secret, 'S1');
      expect(link.hostName, 'Dr. Rao');
      expect(link.expiresAt, isNull);
    });

    test('changing any field breaks the signature', () {
      final host = Identity.generate(sodium);
      final payload = GuestLink.sign(
        sodium,
        host,
        linkId: 'L1',
        secret: 'S1',
        hostName: 'A',
      );
      final json =
          jsonDecode(utf8.decode(b64Decode(payload))) as Map<String, dynamic>;
      for (final change in <String, Object>{
        'n': 'Bank',
        'lid': 'L2',
        's': 'S2',
        'exp': 9999999999,
      }.entries) {
        final tampered = Map<String, dynamic>.from(json)
          ..[change.key] = change.value;
        expect(
          () => GuestLink.parse(
            sodium,
            b64Encode(utf8.encode(jsonEncode(tampered))),
          ),
          throwsA(
            isA<GuestLinkException>().having(
              (e) => e.problem,
              'problem',
              GuestLinkProblem.badSignature,
            ),
          ),
          reason: change.key,
        );
      }
    });

    test('a link signed by someone else is rejected', () {
      final host = Identity.generate(sodium);
      final impostor = Identity.generate(sodium);
      final real = jsonDecode(
        utf8.decode(
          b64Decode(
            GuestLink.sign(
              sodium,
              host,
              linkId: 'L',
              secret: 'S',
              hostName: 'A',
            ),
          ),
        ),
      ) as Map<String, dynamic>;
      final fake = jsonDecode(
        utf8.decode(
          b64Decode(
            GuestLink.sign(
              sodium,
              impostor,
              linkId: 'L',
              secret: 'S',
              hostName: 'A',
            ),
          ),
        ),
      ) as Map<String, dynamic>;
      real['sig'] = fake['sig'];
      expect(
        () => GuestLink.parse(sodium, b64Encode(utf8.encode(jsonEncode(real)))),
        throwsA(isA<GuestLinkException>()),
      );
    });

    test('expired links and garbage are rejected', () {
      final host = Identity.generate(sodium);
      final payload = GuestLink.sign(
        sodium,
        host,
        linkId: 'L',
        secret: 'S',
        hostName: 'A',
        expiresAt: DateTime.utc(2026, 1, 1),
      );
      expect(
        () => GuestLink.parse(
          sodium,
          payload,
          clock: () => DateTime.utc(2026, 1, 2),
        ),
        throwsA(
          isA<GuestLinkException>().having(
            (e) => e.problem,
            'p',
            GuestLinkProblem.expired,
          ),
        ),
      );
      expect(
        GuestLink.parse(
          sodium,
          payload,
          clock: () => DateTime.utc(2025, 12, 31),
        ).linkId,
        'L',
      );
      for (final bad in ['', 'abc', b64Encode(utf8.encode('{"v":1}'))]) {
        expect(
          () => GuestLink.parse(sodium, bad),
          throwsA(isA<GuestLinkException>()),
          reason: bad,
        );
      }
    });
  });

  group('GuestLinkStore', () {
    test(
      'personal links rotate; old ones become revoked; state survives a reload',
      () async {
        final secrets = MemorySecretStore();
        final store = GuestLinkStore(sodium, secrets);
        await store.load();
        final first = await store.ensurePersonal();
        expect(await store.ensurePersonal(), same(first));
        final second = await store.rotatePersonal();
        expect(store.check(first.id, first.secret), KnockCheck.revoked);
        expect(store.check(second.id, second.secret), KnockCheck.ok);

        final reloaded = GuestLinkStore(sodium, secrets);
        await reloaded.load();
        expect(reloaded.personal!.id, second.id);
        expect(reloaded.check(first.id, first.secret), KnockCheck.revoked);
      },
    );

    test('one-time links: usable until admitted, then used; expire after their window', () async {
      var now = DateTime.utc(2026, 10, 7);
      final store = GuestLinkStore(
        sodium,
        MemorySecretStore(),
        clock: () => now,
      );
      final link = await store.createOneTime(validFor: const Duration(days: 1));
      expect(store.check(link.id, link.secret), KnockCheck.ok);
      expect(store.activeOneTime, hasLength(1));
      await store.markAdmitted(link.id);
      expect(store.check(link.id, link.secret), KnockCheck.used);
      expect(store.activeOneTime, isEmpty);

      final later = await store.createOneTime(
        validFor: const Duration(days: 1),
      );
      now = now.add(const Duration(days: 2));
      expect(store.check(later.id, later.secret), KnockCheck.expired);
    });

    test('wrong secrets and unknown links are "unknown"; revoked links are refused', () async {
      final store = GuestLinkStore(sodium, MemorySecretStore());
      final link = await store.createOneTime();
      expect(store.check(link.id, 'wrong'), KnockCheck.unknown);
      expect(store.check('nope', link.secret), KnockCheck.unknown);
      await store.revoke(link.id);
      expect(store.check(link.id, link.secret), KnockCheck.revoked);
    });
  });

  group('waiting room', () {
    late Identity hostId, guestId;
    late GuestLinkStore store;
    late GuestLinkRecord link;
    late List<(String, String, Map<String, Object?>)> hostSent;
    late List<WaitingGuest> admitted;

    setUp(() async {
      hostId = Identity.generate(sodium);
      guestId = Identity.generate(sodium);
      store = GuestLinkStore(sodium, MemorySecretStore());
      link = await store.ensurePersonal();
      hostSent = [];
      admitted = [];
    });

    GuestHost newHost() => GuestHost(
      links: store,
      send: (to, type, body) => hostSent.add((to.id, type, body)),
      onAdmit: (guest) async => admitted.add(guest),
    );

    Map<String, dynamic> knock({String? secret, String name = 'Asha'}) => {
      'knock': 'k1',
      'link': link.id,
      'secret': secret ?? link.secret,
      'name': name,
      'video': true,
    };

    test(
      'a valid knock waits; admitting starts the call and empties the room',
      () async {
        final host = newHost();
        expect(
          host.handle(msg(guestId.publicIdentity, 'guest.knock', knock())),
          isTrue,
        );
        expect(host.waiting.single.name, 'Asha');
        // Repeated knocks refresh the same entry.
        host.handle(msg(guestId.publicIdentity, 'guest.knock', knock()));
        expect(host.waiting, hasLength(1));
        await host.admit('k1');
        expect(admitted.single.guest, guestId.publicIdentity);
        expect(host.waiting, isEmpty);
        host.dispose();
      },
    );

    test(
      'knocks with a wrong secret or revoked link are declined with a reason',
      () async {
        final host = newHost();
        host.handle(
          msg(guestId.publicIdentity, 'guest.knock', knock(secret: 'guess')),
        );
        expect(hostSent.single.$2, 'guest.declined');
        expect(hostSent.single.$3['reason'], 'unknown');
        await store.rotatePersonal();
        host.handle(msg(guestId.publicIdentity, 'guest.knock', knock()));
        expect(hostSent.last.$3['reason'], 'revoked');
        expect(host.waiting, isEmpty);
        host.dispose();
      },
    );

    test('decline and messages reach the guest; leave removes the guest', () {
      final host = newHost();
      host.handle(msg(guestId.publicIdentity, 'guest.knock', knock()));
      host.message('k1', 'Five minutes, please');
      expect(hostSent.last.$2, 'guest.message');
      host.decline('k1');
      expect(hostSent.last.$3, {'knock': 'k1', 'reason': 'declined'});
      host.handle(msg(guestId.publicIdentity, 'guest.knock', knock()));
      host.handle(msg(guestId.publicIdentity, 'guest.leave', {'knock': 'k1'}));
      expect(host.waiting, isEmpty);
      host.dispose();
    });

    test('names are trimmed and capped; empty becomes "Guest"', () {
      final host = newHost();
      host.handle(
        msg(guestId.publicIdentity, 'guest.knock', knock(name: '   ')),
      );
      expect(host.waiting.single.name, 'Guest');
      final other = Identity.generate(sodium);
      host.handle(
        msg(other.publicIdentity, 'guest.knock', knock(name: 'x' * 500)),
      );
      expect(host.waiting.last.name, hasLength(GuestHost.maxNameLength));
      host.dispose();
    });

    test('a guest who stops knocking (closed tab) disappears after 75 s', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026);
        final host = GuestHost(
          links: store,
          send: (to, type, body) {},
          onAdmit: (_) async {},
          clock: () => now,
        );
        host.handle(msg(guestId.publicIdentity, 'guest.knock', knock()));
        now = now.add(const Duration(seconds: 60));
        async.elapse(const Duration(seconds: 60));
        expect(host.waiting, hasLength(1));
        now = now.add(const Duration(seconds: 30));
        async.elapse(const Duration(seconds: 30));
        expect(host.waiting, isEmpty);
        host.dispose();
      });
    });

    test(
      'the guest side keeps knocking, recognises its admission and declines',
      () {
        fakeAsync((async) {
          final guestLink = GuestLink(
            host: hostId.publicIdentity,
            linkId: link.id,
            secret: link.secret,
            hostName: 'Dr. Rao',
          );
          final sent = <String>[];
          final visit = GuestVisit(
            link: guestLink,
            send: (to, type, body) => sent.add(type),
            newKnockId: () => 'k1',
          );
          visit.knock(name: 'Asha', video: true);
          expect(visit.phase, GuestVisitPhase.waiting);
          async.elapse(const Duration(seconds: 60));
          expect(sent.where((t) => t == 'guest.knock'), hasLength(3));

          // An invite from someone else, or for another knock, is not an admission.
          final stranger = Identity.generate(sodium).publicIdentity;
          expect(
            visit.isAdmission(msg(stranger, 'call.invite', {'knock': 'k1'})),
            isFalse,
          );
          expect(
            visit.isAdmission(
              msg(hostId.publicIdentity, 'call.invite', {'knock': 'x'}),
            ),
            isFalse,
          );
          expect(
            visit.isAdmission(
              msg(hostId.publicIdentity, 'call.invite', {'knock': 'k1'}),
            ),
            isTrue,
          );
          expect(visit.phase, GuestVisitPhase.admitted);
          async.elapse(const Duration(seconds: 60));
          expect(
            sent.where((t) => t == 'guest.knock'),
            hasLength(3),
            reason: 'stops knocking',
          );

          visit.reset();
          visit.knock(name: 'Asha', video: true);
          visit.handle(
            msg(hostId.publicIdentity, 'guest.message', {
              'knock': 'k1',
              'text': 'Soon!',
            }),
          );
          expect(visit.hostMessage, 'Soon!');
          visit.handle(
            msg(stranger, 'guest.declined', {
              'knock': 'k1',
              'reason': 'declined',
            }),
          );
          expect(
            visit.phase,
            GuestVisitPhase.waiting,
            reason: 'only the host can decline',
          );
          visit.handle(
            msg(hostId.publicIdentity, 'guest.declined', {
              'knock': 'k1',
              'reason': 'used',
            }),
          );
          expect(visit.phase, GuestVisitPhase.declined);
          expect(visit.declineReason, 'used');
          visit.dispose();
        });
      },
    );
  });
}
