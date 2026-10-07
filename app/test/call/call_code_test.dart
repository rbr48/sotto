import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/call/call_code.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  test('a call link round-trips to the signed identity', () {
    final identity = Identity.generate(sodium);
    final card = identity.card(sodium);
    final link = CallCode.link(Uri.parse('https://sotto.example/'), card);
    expect(link, startsWith('https://sotto.example/?call='));
    expect(CallCode.parse(sodium, link), identity.publicIdentity);
    expect(
      CallCode.parse(sodium, '  ${CallCode.encode(card)}\n'),
      identity.publicIdentity,
    );
  });

  test('links keep a non-default port and path', () {
    final card = Identity.generate(sodium).card(sodium);
    final link = CallCode.link(Uri.parse('http://localhost:8099/app/'), card);
    expect(link, startsWith('http://localhost:8099/app/?call='));
  });

  test('garbage and tampered links are rejected', () {
    final card = Identity.generate(sodium).card(sodium);
    final code = CallCode.encode(card);
    final tampered = code.replaceRange(20, 21, code[20] == 'A' ? 'B' : 'A');
    for (final input in [
      '',
      'hello',
      'https://example.com/?call=abc',
      tampered,
    ]) {
      expect(
        () => CallCode.parse(sodium, input),
        throwsA(isA<InvalidIdentityException>()),
        reason: input,
      );
    }
  });
}
