import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/contacts/contact_link.dart';
import 'package:sotto/contacts/profile_exchange.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

/// Two people on an in-memory relay: [from] is what the relay would report.
class _Relay {
  final inboxes = <String, void Function(String from, String body)>{};
  final sent = <({String from, String to, String body})>[];

  void Function(String to, String body) sender(String from) => (to, body) {
    sent.add((from: from, to: to, body: body));
    // Delivered asynchronously, as over a socket.
    scheduleMicrotask(() => inboxes[to]?.call(from, body));
  };
}

void main() {
  late Sodium sodium;
  late Identity meera, visitor;
  late _Relay relay;
  var now = DateTime.utc(2026, 10, 8, 12);

  ProfileExchange exchange(Identity identity, {PublicProfile? profile}) {
    final codec = EnvelopeCodec(sodium, identity, clock: () => now);
    final ex = ProfileExchange(
      sodium: sodium,
      identity: identity,
      codec: codec,
      send: relay.sender(identity.id),
      profile: profile == null ? null : () => profile,
      clock: () => now,
    );
    relay.inboxes[identity.id] = (from, body) {
      if (ProfileExchange.isRequest(body)) {
        ex.answer(from, body);
        return;
      }
      try {
        ex.handleReply(codec.open(body, expectedSender: from));
      } on EnvelopeException {
        // dropped, as the app does
      }
    };
    return ex;
  }

  setUpAll(() async {
    sodium = await SottoCrypto.init();
  });

  setUp(() {
    now = DateTime.utc(2026, 10, 8, 12);
    meera = Identity.generate(sodium);
    visitor = Identity.generate(sodium);
    relay = _Relay();
  });

  group('short links', () {
    final base = Uri.parse('https://call.sottocall.com/');

    test('carry only the signing key and are short', () {
      final call = ContactLink.createShortCall(base, meera.publicIdentity);
      final contact = ContactLink.createShort(base, meera.publicIdentity);
      expect(call, 'https://call.sottocall.com/?call=${meera.id}');
      expect(contact, 'https://call.sottocall.com/#c=${meera.id}');
      expect(call.length, lessThan(80));
      for (final link in [call, contact, meera.id]) {
        expect(b64Encode(ContactLink.shortKeyOf(link)!), meera.id);
      }
    });

    test('full links and junk are not short links', () {
      final full = ContactLink.create(
        sodium,
        meera,
        base: base,
        name: 'Dr Meera Rao',
      );
      expect(ContactLink.shortKeyOf(full), isNull);
      expect(ContactLink.shortKeyOf('hello'), isNull);
      expect(ContactLink.shortKeyOf('https://x/?call=${'A' * 42}'), isNull);
      // Full links still work as before.
      expect(ContactLink.parse(sodium, full).name, 'Dr Meera Rao');
    });
  });

  group('lookup', () {
    test('returns the verified identity, name and organisation', () async {
      exchange(
        meera,
        profile: (name: 'Dr Meera Rao', organisation: 'Rao Physiotherapy', avatar: null),
      );
      final invite = await exchange(visitor)
          .fetch(meera.publicIdentity.signKey);
      expect(invite.identity, meera.publicIdentity);
      expect(invite.name, 'Dr Meera Rao');
      expect(invite.organisation, 'Rao Physiotherapy');
    });

    test('only the request travels unencrypted, and it holds only the '
        "requester's public card", () async {
      exchange(meera, profile: (name: 'Dr Meera Rao', organisation: '', avatar: null));
      await exchange(visitor).fetch(meera.publicIdentity.signKey);
      final request = relay.sent.firstWhere((m) => m.to == meera.id).body;
      expect(request, startsWith(ProfileExchange.requestPrefix));
      final reply = relay.sent.firstWhere((m) => m.to == visitor.id).body;
      expect(reply, isNot(contains('Meera')));
    });

    test('a reply signed by someone else is not accepted', () async {
      final mallory = Identity.generate(sodium);
      exchange(mallory, profile: (name: 'Dr Meera Rao', organisation: '', avatar: null));
      final visitorSide = exchange(visitor);
      // Mallory answers a lookup for Meera's key: the reply is signed by
      // Mallory, so it can't complete the lookup for Meera.
      relay.inboxes[meera.id] = (from, body) =>
          relay.inboxes[mallory.id]!(from, body);
      await expectLater(
        visitorSide.fetch(
          meera.publicIdentity.signKey,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<ProfileUnavailableException>()),
      );
    });

    test('nobody online, or no profile to share: unavailable', () async {
      exchange(meera); // a guest page: answers nothing
      await expectLater(
        exchange(visitor).fetch(
          meera.publicIdentity.signKey,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<ProfileUnavailableException>()),
      );
    });

    test('a request whose card is not the sender is ignored', () {
      final meeraSide = exchange(
        meera,
        profile: (name: 'Dr Meera Rao', organisation: '', avatar: null),
      );
      final other = Identity.generate(sodium);
      final request =
          '${ProfileExchange.requestPrefix}'
          '${b64Encode(other.card(sodium).encode().codeUnits)}';
      meeraSide.answer(visitor.id, request);
      expect(relay.sent, isEmpty);
    });

    test('answers are rate limited per requester', () {
      final meeraSide = exchange(
        meera,
        profile: (name: 'Dr Meera Rao', organisation: '', avatar: null),
      );
      final request =
          '${ProfileExchange.requestPrefix}'
          '${b64Encode(visitor.card(sodium).encode().codeUnits)}';
      meeraSide
        ..answer(visitor.id, request)
        ..answer(visitor.id, request);
      expect(relay.sent, hasLength(1));
      now = now.add(ProfileExchange.perRequesterGap);
      meeraSide.answer(visitor.id, request);
      expect(relay.sent, hasLength(2));
    });
  });
}
