import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/forward_picker.dart';
import 'package:sotto/contacts/contact_book.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/core/theme.dart';
import 'package:sotto/crypto/identity.dart';
import 'package:sotto/crypto/identity_store.dart';

Contact _contact(String name, int key) => Contact(
  identity: PublicIdentity(
    signKey: Uint8List.fromList(List.filled(32, key)),
    boxKey: Uint8List(32),
  ),
  name: name,
  addedAt: DateTime(2024),
);

void main() {
  final bob = _contact('Bob', 1);
  final carol = _contact('Carol', 2);
  late ChatStore store;
  late ChatManager chat;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    chat = ChatManager(
      myId: 'alice',
      store: store,
      isContact: {bob.identity.id}.contains,
      send: (to, type, body, callId) {},
      iceServers: () async => const [],
      hideIp: () => false,
      createRtc: ({required iceServers, required relayOnly}) async =>
          throw StateError('no connection in this test'),
      clock: DateTime.now,
    );
  });

  tearDown(() async {
    await chat.dispose();
  });

  /// Pumps a button that forwards "Salaam" over [contacts]. The result of each
  /// forward (the contact, or null) is appended to [results].
  Future<void> pumpForward(
    WidgetTester tester,
    List<Contact> contacts,
    List<Contact?> results,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SottoTheme.light(),
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await forwardText(
                    context,
                    chat: chat,
                    contacts: contacts,
                    text: 'Salaam',
                  ),
                );
              },
              child: const Text('Forward'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the contacts under the title, and only those', (
    tester,
  ) async {
    final results = <Contact?>[];
    await pumpForward(tester, [bob, carol], results);

    expect(find.text('Forward to'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
  });

  testWidgets('choosing a contact sends the text there as a forwarded text', (
    tester,
  ) async {
    final results = <Contact?>[];
    await pumpForward(tester, [bob], results);

    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    // The send waits on the store, which runs in real time.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(results.single?.identity.id, bob.identity.id);
    final sent = await tester.runAsync(() => store.messages(bob.identity.id));
    expect(sent!.single.text, 'Salaam');
    expect(sent.single.forwarded, isTrue);
    expect(sent.single.outgoing, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(chat.dispose);
  });

  testWidgets('dismissing the list sends nothing', (tester) async {
    final results = <Contact?>[];
    await pumpForward(tester, [bob], results);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(results.single, isNull);
    final sent = await tester.runAsync(() => store.messages(bob.identity.id));
    expect(sent, isEmpty);
  });

  testWidgets('with no contacts, it says so and sends nothing', (tester) async {
    final results = <Contact?>[];
    await pumpForward(tester, const [], results);

    expect(
      find.text('Add contacts from the Contacts tab first.'),
      findsOneWidget,
    );
    expect(results.single, isNull);
    expect(find.text('Forward to'), findsNothing);
  });
}
