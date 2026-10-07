import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/poc/poc_call_controller.dart';
import 'package:sotto/poc/poc_call_page.dart';

void main() {
  Future<PocCallController> pumpPage(WidgetTester tester) async {
    final controller = PocCallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: PocCallPage(controller: controller)),
    );
    return controller;
  }

  testWidgets('shows the join form when idle', (tester) async {
    await pumpPage(tester);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byKey(const Key('server')), findsOneWidget);
    expect(find.byKey(const Key('room')), findsOneWidget);
    expect(find.byKey(const Key('join')), findsOneWidget);
  });

  testWidgets('validates the server address and room code before joining', (
    tester,
  ) async {
    final controller = await pumpPage(tester);

    await tester.enterText(
      find.byKey(const Key('server')),
      'http://example.com',
    );
    await tester.enterText(find.byKey(const Key('room')), 'a b');
    await tester.tap(find.byKey(const Key('join')));
    await tester.pump();

    expect(find.text('Enter a ws:// or wss:// address'), findsOneWidget);
    expect(find.text('4–64 letters, numbers, - or _'), findsOneWidget);
    expect(controller.status, PocCallStatus.idle);
  });

  testWidgets('pre-fills the room code from a link', (tester) async {
    final controller = PocCallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PocCallPage(controller: controller, initialRoom: 'from-link'),
      ),
    );
    expect(find.text('from-link'), findsOneWidget);
  });
}
