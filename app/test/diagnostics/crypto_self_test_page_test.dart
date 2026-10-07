import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/diagnostics/crypto_self_test_page.dart';

void main() {
  testWidgets('reports a passing self-test', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CryptoSelfTestPage()));
    // libsodium loads asynchronously outside the fake test clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(find.text('Self-test passed'), findsOneWidget);
  });
}
