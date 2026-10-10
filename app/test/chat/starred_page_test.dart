import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/chat_page.dart';
import 'package:sotto/chat/ui/starred_page.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/crypto/identity_store.dart';

ChatMessage _message(
  String contactId,
  String body, {
  required int ts,
  bool starred = false,
  bool deletedForAll = false,
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: contactId,
  outgoing: true,
  ts: ts,
  text: deletedForAll ? '' : body,
  state: ChatState.delivered,
  starred: starred,
  deletedForAll: deletedForAll,
);

void main() {
  late ChatStore store;
  late ChatManager chat;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    chat = ChatManager(
      myId: 'alice',
      store: store,
      isContact: {'bob', 'carol', 'dave'}.contains,
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

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  Future<void> pumpStarred(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: StarredPage(chat: chat),
      ),
    );
    await settle(tester);
  }

  testWidgets(
    'lists the starred messages of every chat, archived ones too, and no others',
    (tester) async {
      await tester.runAsync(() async {
        await store.add(
          _message('bob', 'Starred in Bob', ts: 3000, starred: true),
        );
        await store.add(_message('bob', 'Plain in Bob', ts: 4000));
        await store.add(
          _message('carol', 'Starred in Carol', ts: 2000, starred: true),
        );
        await store.add(
          _message('carol', '', ts: 1000, starred: true, deletedForAll: true),
        );
        await store.add(
          _message('dave', 'Starred in archive', ts: 500, starred: true),
        );
        await store.setArchived('dave', true);
      });
      await pumpStarred(tester);

      expect(find.text('Starred in Bob'), findsOneWidget);
      expect(find.text('Starred in Carol'), findsOneWidget);
      expect(find.text('Starred in archive'), findsOneWidget);
      expect(find.text('Plain in Bob'), findsNothing);
      // The deleted message is not shown, so only three rows exist.
      expect(find.byType(ListTile), findsNWidgets(3));
      // Newest first.
      expect(
        tester.getTopLeft(find.text('Starred in Bob')).dy,
        lessThan(tester.getTopLeft(find.text('Starred in Carol')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Starred in Carol')).dy,
        lessThan(tester.getTopLeft(find.text('Starred in archive')).dy),
      );
    },
  );

  testWidgets('the star on a row unstars the message, and the row goes', (
    tester,
  ) async {
    final kept = _message('bob', 'Unstar me', ts: 3000, starred: true);
    await tester.runAsync(() => store.add(kept));
    await pumpStarred(tester);

    await tester.tap(find.byTooltip('Unstar'));
    await settle(tester);

    expect(find.text('Unstar me'), findsNothing);
    final after = await tester.runAsync(() => store.find('bob', kept.id));
    expect(after?.starred, isFalse);
  });

  testWidgets('says so when nothing is starred', (tester) async {
    await pumpStarred(tester);
    expect(
      find.text('No starred messages. Star a message to find it here.'),
      findsOneWidget,
    );
  });

  testWidgets('a starred message opens its chat at that message', (
    tester,
  ) async {
    final target = _message('carol', 'Open me', ts: 3000, starred: true);
    await tester.runAsync(() => store.add(target));
    await pumpStarred(tester);

    await tester.tap(find.text('Open me'));
    // The route starts its transition on one frame and runs it on the next.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final page = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(page.contactId, 'carol');
    expect(page.focusMessageId, target.id);
    await tester.pumpWidget(const SizedBox());
  });
}
