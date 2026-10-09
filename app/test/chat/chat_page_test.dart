import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/chat_page.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/crypto/identity_store.dart';

ChatMessage _message(
  String text, {
  required bool outgoing,
  required ChatState state,
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: 1700000000000,
  text: text,
  state: state,
);

void main() {
  late ChatStore store;
  late ChatManager chat;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    chat = ChatManager(
      myId: 'alice',
      store: store,
      isContact: {'bob'}.contains,
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

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ChatPage(chat: chat, contactId: 'bob', name: 'Bob'),
      ),
    );
    // The store is read asynchronously; let it finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  testWidgets('shows both sides of the chat, with the state of each message', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.add(
        _message('Hello there', outgoing: true, state: ChatState.delivered),
      );
      await store.add(
        _message('Hi from Bob', outgoing: false, state: ChatState.received),
      );
      await store.add(
        _message('Lost in transit', outgoing: true, state: ChatState.notSent),
      );
    });

    await pumpPage(tester);

    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('Hi from Bob'), findsOneWidget);
    expect(find.text('Lost in transit'), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an empty chat says where messages go', (tester) async {
    await pumpPage(tester);
    expect(
      find.text(
        'No messages yet. Messages go directly to them while you are both online.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('writing a message stores it and shows it as sending', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'Salaam');
    await tester.tap(find.byTooltip('Send'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(find.text('Salaam'), findsOneWidget);
    expect(find.text('Sending'), findsOneWidget);
    final stored = await tester.runAsync(() => store.messages('bob'));
    expect(stored!.single.text, 'Salaam');

    // Sending starts the chat's periodic check: stop it before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(chat.dispose);
  });
}
