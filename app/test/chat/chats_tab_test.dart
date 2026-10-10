import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/call/call_controller.dart';
import 'package:sotto/call/screen_awake.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/chats_tab.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/crypto/identity_store.dart';
import 'package:sotto/storage/browser_storage.dart';

import '../call/devices_test.dart' show FakeLister;

class _NoScreenAwake implements ScreenAwake {
  @override
  Future<void> keepOn(bool on) async {}
}

/// A call controller whose chat manager is the test's.
class _CallsWith extends CallController {
  _CallsWith(this._chat)
    : super(
        relayUrl: Uri.parse('ws://localhost:1/relay'),
        linkBase: Uri.parse('http://localhost:1/'),
        screenAwake: _NoScreenAwake(),
      );

  final ChatManager _chat;

  @override
  ChatManager? get chat => _chat;
}

/// A message from [contactId]. An incoming one is unread unless [read].
ChatMessage _message(
  String contactId, {
  required int ts,
  bool outgoing = false,
  bool read = false,
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: contactId,
  outgoing: outgoing,
  ts: ts,
  text: 'Hi from $contactId',
  state: outgoing ? ChatState.delivered : ChatState.received,
  read: outgoing || read,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatStore store;
  late ChatManager chat;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    chat = ChatManager(
      myId: 'alice',
      store: store,
      isContact: {'anna', 'ben', 'cy', 'dora', 'carol', 'bob'}.contains,
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

  Future<void> pumpTab(WidgetTester tester) async {
    final app = AppController(
      relayUrl: Uri.parse('ws://localhost:1/relay'),
      linkBase: Uri.parse('http://localhost:1/'),
      persistent: false,
      browserStorage: MemoryBrowserStorage(),
      deviceLister: FakeLister.new,
      startCalls: false,
    );
    await tester.runAsync(() async {
      await app.start();
      await app.completeOnboarding(name: 'Alice');
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ChatsTab(app: app, calls: _CallsWith(chat)),
      ),
    );
    await settle(tester);
  }

  /// Opens the menu of the chat named [name] by a long press, and taps [item].
  Future<void> chooseFromMenu(
    WidgetTester tester,
    String name,
    String item,
  ) async {
    await tester.longPress(find.text(name));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(item));
    await settle(tester);
  }

  group('the archive section', () {
    testWidgets(
      'archived chats appear only under the Archived row, with their count and unread total',
      (tester) async {
        await tester.runAsync(() async {
          await store.add(_message('bob', ts: 3000));
          await store.add(_message('carol', ts: 2000));
          await store.add(_message('carol', ts: 2100));
          await store.add(_message('dora', ts: 1000));
          await store.setArchived('carol', true);
          await store.setArchived('dora', true);
        });
        await pumpTab(tester);

        // Collapsed: the row shows two archived chats and three unread.
        expect(find.text('Archived (2)'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('bob'), findsOneWidget);
        expect(find.text('carol'), findsNothing);
        expect(find.text('dora'), findsNothing);

        await tester.tap(find.text('Archived (2)'));
        await settle(tester);

        expect(find.text('carol'), findsOneWidget);
        expect(find.text('dora'), findsOneWidget);
        // Each chat is listed once: the main list leaves archived ones out.
        expect(find.text('bob'), findsOneWidget);
        expect(find.text('Archived (2)'), findsOneWidget);
      },
    );

    testWidgets('there is no Archived row when nothing is archived', (
      tester,
    ) async {
      await tester.runAsync(() => store.add(_message('bob', ts: 3000)));
      await pumpTab(tester);

      expect(find.textContaining('Archived ('), findsNothing);
      expect(find.text('bob'), findsOneWidget);
    });

    testWidgets(
      'the Archived row opens closed again once its last chat leaves',
      (tester) async {
        await tester.runAsync(() => store.add(_message('bob', ts: 3000)));
        await pumpTab(tester);
        await chooseFromMenu(tester, 'bob', 'Archive');
        await tester.tap(find.text('Archived (1)'));
        await settle(tester);
        expect(find.text('bob'), findsOneWidget);

        await chooseFromMenu(tester, 'bob', 'Unarchive');
        expect(find.text('Archived (1)'), findsNothing);

        await chooseFromMenu(tester, 'bob', 'Archive');
        expect(find.text('Archived (1)'), findsOneWidget);
        expect(find.text('bob'), findsNothing);
      },
    );

    testWidgets(
      'a long press archives a chat, which then moves under the row',
      (tester) async {
        await tester.runAsync(() => store.add(_message('bob', ts: 3000)));
        await pumpTab(tester);

        await chooseFromMenu(tester, 'bob', 'Archive');

        expect(find.text('Archived (1)'), findsOneWidget);
        expect(find.text('bob'), findsNothing);
        expect(
          (await tester.runAsync(() => store.chatMeta('bob')))?.archived,
          isTrue,
        );
      },
    );
  });

  group('pins', () {
    testWidgets('pinned chats come first, in the order pinned, at most three', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(_message('anna', ts: 4000, read: true));
        await store.add(_message('ben', ts: 3000, read: true));
        await store.add(_message('cy', ts: 2000, read: true));
        await store.add(_message('dora', ts: 1000, read: true));
      });
      await pumpTab(tester);

      await chooseFromMenu(tester, 'dora', 'Pin to top');
      await chooseFromMenu(tester, 'cy', 'Pin to top');
      await chooseFromMenu(tester, 'ben', 'Pin to top');

      expect(find.text('Pinned'), findsOneWidget);
      final y = {
        for (final name in ['dora', 'cy', 'ben', 'anna'])
          name: tester.getTopLeft(find.text(name)).dy,
      };
      // The pins keep their order of pinning, then the unpinned chat.
      expect(y['dora']!, lessThan(y['cy']!));
      expect(y['cy']!, lessThan(y['ben']!));
      expect(y['ben']!, lessThan(y['anna']!));

      // A fourth pin is refused, and the screen says why.
      await chooseFromMenu(tester, 'anna', 'Pin to top');
      expect(
        find.text('You can pin up to three chats. Unpin one to pin another.'),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(() => store.chatMeta('anna')))?.pinnedAt,
        isNull,
      );
    });

    testWidgets(
      'a pinned chat shows a pin icon, and a muted one a muted icon',
      (tester) async {
        await tester.runAsync(() async {
          await store.add(_message('anna', ts: 4000, read: true));
          await store.add(_message('ben', ts: 3000, read: true));
          await store.setMuted('ben', true);
          await store.setPinned('anna', true, at: 1);
        });
        await pumpTab(tester);

        expect(find.byIcon(Icons.push_pin), findsOneWidget);
        expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      },
    );
  });

  group('mute', () {
    testWidgets('a muted chat\'s unread badge is grey; another stays primary', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(_message('ben', ts: 3000));
        await store.add(_message('ben', ts: 3100));
        await store.add(_message('cy', ts: 2000));
        await store.add(_message('cy', ts: 2100));
        await store.setMuted('ben', true);
      });
      await pumpTab(tester);

      final scheme = Theme.of(tester.element(find.byType(ChatsTab)))
          .colorScheme;
      Color badgeColor(String name) {
        final badge = find.descendant(
          of: find.widgetWithText(ListTile, name),
          matching: find.text('2'),
        );
        final container = tester.widget<Container>(
          find.ancestor(of: badge, matching: find.byType(Container)).first,
        );
        return (container.decoration! as BoxDecoration).color!;
      }

      expect(badgeColor('ben'), scheme.surfaceContainerHighest);
      expect(badgeColor('cy'), scheme.primary);
    });
  });
}
