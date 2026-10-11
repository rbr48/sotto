import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/group_create_page.dart';
import 'package:sotto/crypto/identity_store.dart';

import 'support/group_fixtures.dart';

void main() {
  late ChatStore store;
  late ChatManager chat;
  late List<({String to, String type})> sent;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    sent = [];
    chat = groupChat(store: store, sent: sent);
  });

  tearDown(() async {
    await chat.dispose();
  });

  /// Opens the page from a button, and records what it closes with.
  Future<List<ChatGroup?>> pumpPage(WidgetTester tester) async {
    final results = <ChatGroup?>[];
    await tester.pumpWidget(
      appWith(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  results.add(
                    await Navigator.of(context).push<ChatGroup>(
                      MaterialPageRoute(
                        builder: (_) => GroupCreatePage(
                          chat: chat,
                          contacts: groupContacts,
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  Checkbox box(WidgetTester tester, String name) => tester.widget<Checkbox>(
    find.descendant(
      of: find.widgetWithText(CheckboxListTile, name),
      matching: find.byType(Checkbox),
    ),
  );

  FilledButton createButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Create group'),
  );

  testWidgets('at most three contacts can be chosen', (tester) async {
    await pumpPage(tester);
    for (final name in ['Anna', 'Ben', 'Cy']) {
      await tester.tap(find.text(name));
      await tester.pump();
    }
    expect(find.text('3 of 3 chosen'), findsOneWidget);
    // The fourth is greyed out, and a tap does not choose it.
    expect(box(tester, 'Dora').onChanged, isNull);
    await tester.tap(find.text('Dora'));
    await tester.pump();
    expect(box(tester, 'Dora').value, isFalse);
    expect(find.text('3 of 3 chosen'), findsOneWidget);
    // Taking one off frees a place again.
    await tester.tap(find.text('Cy'));
    await tester.pump();
    expect(box(tester, 'Dora').onChanged, isNotNull);
  });

  testWidgets('at least two contacts are needed to create', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), 'Trip');
    expect(createButton(tester).onPressed, isNull);
    await tester.tap(find.text('Anna'));
    await tester.pump();
    expect(find.text('1 of 3 chosen'), findsOneWidget);
    expect(createButton(tester).onPressed, isNull);
    await tester.tap(find.text('Ben'));
    await tester.pump();
    expect(createButton(tester).onPressed, isNotNull);
  });

  testWidgets('the name is required, and nothing is made without one', (
    tester,
  ) async {
    final results = await pumpPage(tester);
    await tester.tap(find.text('Anna'));
    await tester.tap(find.text('Ben'));
    await tester.pump();
    // Spaces only are no name.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Create group'));
    await tester.pump();
    expect(find.text('Give the group a name.'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await store.groups(), isEmpty);
    });
    expect(results, isEmpty);
    expect(sent, isEmpty);
  });

  testWidgets('the name takes at most 64 characters', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField), 'x' * 70);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLength, 64);
    expect(field.controller!.text.length, 64);
  });

  testWidgets('creating calls the group manager, which invites each one', (
    tester,
  ) async {
    final results = await pumpPage(tester);
    await tester.enterText(find.byType(TextField), '  Weekend trip ');
    await tester.tap(find.text('Anna'));
    await tester.tap(find.text('Cy'));
    await tester.pump();
    await tester.tap(find.text('Create group'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(results, hasLength(1));
    final group = results.single!;
    expect(group.name, 'Weekend trip');
    expect(group.memberIds, [selfId, memberId(2), memberId(4)]);
    await tester.runAsync(() async {
      expect((await store.group(group.id))?.name, 'Weekend trip');
    });
    expect(
      sent.where((s) => s.type == 'group.invite').map((s) => s.to).toSet(),
      {memberId(2), memberId(4)},
    );
  });
}
