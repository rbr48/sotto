import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late Sodium sodium;
  late Identity alice, bob, mallory;
  var now = DateTime.utc(2026, 10, 7, 12);

  EnvelopeCodec codecFor(Identity identity) =>
      EnvelopeCodec(sodium, identity, clock: () => now);

  Matcher throwsEnvelope(EnvelopeError error) =>
      throwsA(isA<EnvelopeException>().having((e) => e.error, 'error', error));

  setUpAll(() async {
    sodium = await SottoCrypto.init();
  });

  setUp(() {
    now = DateTime.utc(2026, 10, 7, 12);
    alice = Identity.generate(sodium);
    bob = Identity.generate(sodium);
    mallory = Identity.generate(sodium);
  });

  String aliceToBob({Map<String, Object?> body = const {'sdp': 'v=0'}}) =>
      codecFor(alice).seal(
        recipient: bob.publicIdentity,
        type: 'sdp.offer',
        callId: 'call-1',
        body: body,
      );

  test('round trip: recipient gets the verified message', () {
    final opened = codecFor(bob).open(aliceToBob(), expectedSender: alice.id);
    expect(opened.type, 'sdp.offer');
    expect(opened.callId, 'call-1');
    expect(opened.body, {'sdp': 'v=0'});
    expect(opened.sender, alice.publicIdentity);
    expect(opened.sentAt, now);
  });

  test('the envelope reveals nothing readable', () {
    final envelope = aliceToBob(body: {'secret': 'attorney-client privileged'});
    expect(envelope, isNot(contains('attorney')));
    expect(
      utf8.decode(b64Decode(envelope), allowMalformed: true),
      isNot(contains('sdp')),
    );
  });

  test('each envelope is different even for the same message', () {
    expect(aliceToBob(), isNot(aliceToBob()));
  });

  test('flipping any byte makes the envelope fail to decrypt', () {
    final sealed = b64Decode(aliceToBob());
    for (final index in [0, 31, 32, sealed.length ~/ 2, sealed.length - 1]) {
      final tampered = Uint8List.fromList(sealed)..[index] ^= 0x01;
      expect(
        () => codecFor(bob).open(b64Encode(tampered)),
        throwsEnvelope(EnvelopeError.undecryptable),
        reason: 'byte $index',
      );
    }
  });

  test('only the recipient can open it', () {
    expect(
      () => codecFor(mallory).open(aliceToBob()),
      throwsEnvelope(EnvelopeError.undecryptable),
    );
  });

  test('a signed message re-sealed to someone else is rejected', () {
    // Bob decrypts Alice's message and forwards the signed plaintext to Mallory.
    final plain = sodium.crypto.box.sealOpen(
      cipherText: b64Decode(aliceToBob()),
      publicKey: bob.publicIdentity.boxKey,
      secretKey: bob.boxSecretKey,
    );
    final forwarded = sodium.crypto.box.seal(
      message: plain,
      publicKey: mallory.publicIdentity.boxKey,
    );
    expect(
      () => codecFor(mallory).open(b64Encode(forwarded)),
      throwsEnvelope(EnvelopeError.wrongRecipient),
    );
  });

  test(
    'a message claiming to be from Alice but signed by Mallory is rejected',
    () {
      final inner = utf8.encode(
        jsonEncode({
          'v': 1,
          'from': alice.id,
          'fromBox': b64Encode(alice.publicIdentity.boxKey),
          'to': bob.id,
          'ts': now.millisecondsSinceEpoch,
          'n': b64Encode(sodium.randombytes.buf(16)),
          'type': 'call.end',
          'body': <String, Object>{},
        }),
      );
      final forgedSignature = sodium.crypto.sign.detached(
        message: concatBytes([domainLabel('sotto-msg-v1'), inner]),
        secretKey: mallory.signSecretKey,
      );
      final envelope = sodium.crypto.box.seal(
        message: concatBytes([forgedSignature, inner]),
        publicKey: bob.publicIdentity.boxKey,
      );
      expect(
        () => codecFor(bob).open(b64Encode(envelope)),
        throwsEnvelope(EnvelopeError.badSignature),
      );
    },
  );

  test('a genuine message from an unexpected sender is rejected', () {
    final fromMallory = codecFor(
      mallory,
    ).seal(recipient: bob.publicIdentity, type: 'call.invite', body: const {});
    expect(
      () => codecFor(bob).open(fromMallory, expectedSender: alice.id),
      throwsEnvelope(EnvelopeError.unexpectedSender),
    );
  });

  test('replays are rejected', () {
    final envelope = aliceToBob();
    final bobCodec = codecFor(bob);
    bobCodec.open(envelope);
    expect(
      () => bobCodec.open(envelope),
      throwsEnvelope(EnvelopeError.replayed),
    );
  });

  test('old messages and messages from the far future are rejected', () {
    final envelope = aliceToBob();
    final bobCodec = codecFor(bob);
    now = now.add(const Duration(minutes: 2, seconds: 1));
    expect(
      () => bobCodec.open(envelope),
      throwsEnvelope(EnvelopeError.expired),
    );

    now = DateTime.utc(2026, 10, 7, 12);
    final fromFuture = codecFor(alice)
        .seal(recipient: bob.publicIdentity, type: 't', body: const {});
    now = now.subtract(const Duration(minutes: 2, seconds: 1));
    expect(
      () => bobCodec.open(fromFuture),
      throwsEnvelope(EnvelopeError.expired),
    );
  });

  test('messages within the clock-skew window are accepted', () {
    final envelope = aliceToBob();
    now = now.subtract(const Duration(minutes: 1));
    expect(codecFor(bob).open(envelope).type, 'sdp.offer');
  });

  test('oversized messages are refused before sending', () {
    expect(
      () => aliceToBob(body: {'big': 'x' * (EnvelopeCodec.maxInnerBytes + 1)}),
      throwsEnvelope(EnvelopeError.tooLarge),
    );
  });

  test('malformed input never escapes as anything but EnvelopeException', () {
    final bobCodec = codecFor(bob);
    for (final input in [
      '',
      'not base64!',
      'AAAA',
      'AAAA=',
      '${aliceToBob()}=',
    ]) {
      expect(
        () => bobCodec.open(input),
        throwsA(isA<EnvelopeException>()),
        reason: input,
      );
    }
    final random = Random(42);
    for (var i = 0; i < 300; i++) {
      final bytes = Uint8List.fromList(
        List.generate(random.nextInt(400), (_) => random.nextInt(256)),
      );
      expect(
        () => bobCodec.open(b64Encode(bytes)),
        throwsA(isA<EnvelopeException>()),
      );
    }
  });

  test('a correctly sealed but invalid inner message is rejected', () {
    for (final inner in ['not json', '[]', '{"v":2}', '{"v":1,"from":"x"}']) {
      final envelope = sodium.crypto.box.seal(
        message: concatBytes([Uint8List(64), utf8.encode(inner)]),
        publicKey: bob.publicIdentity.boxKey,
      );
      expect(
        () => codecFor(bob).open(b64Encode(envelope)),
        throwsEnvelope(EnvelopeError.invalidMessage),
        reason: inner,
      );
    }
  });
}
