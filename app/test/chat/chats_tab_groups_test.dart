import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/call/call_controller.dart';
import 'package:sotto/call/screen_awake.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/chat_page.dart';
import 'package:sotto/chat/ui/chats_tab.dart';
import 'package:sotto/chat/ui/group_create_page.dart';
import 'package:sotto/chat/ui/starred_page.dart';
import 'package:sotto/crypto/identity_store.dart';
import 'package:sotto/storage/browser_storage.dart';

import '../call/devices_test.dart' show FakeLister;
import 'support/group_fixtures.dart';

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

void main() {
  late ChatStore store;
  late ChatManager chat;
  final anna = memberId(2);
  final ben = memberId(3);

  setUp(() {
    store = ChatStore(MemorySecretStore());
    chat = groupChat(store: store);
  });

  tearDown(() async {
    await chat.dispose();
  });

  /// A group with Anna and Ben, with one unread message from Anna, and a
  /// one-to-one chat with Ben.
  Future<ChatGroup> seed(WidgetTester tester) async {
    final group = groupOf(name: 'Weekend trip', others: [anna, ben]);
    await tester.runAsync(() async {
      await store.saveGroup(group);
      await store.add(
        groupMessage(
          group,
          author: anna,
          text: 'See you there',
          ts: 3000,
        ).copyWith(read: false),
      );
      await store.add(
        ChatMessage(
          id: 'one-to-one',
          contactId: ben,
          outgoing: false,
          ts: 2000,
          text: 'Hi from Ben',
          state: ChatState.received,
        ),
      );
    });
    return group;
  }

  Future<void> pumpTab(WidgetTester tester, {required bool groups}) async {
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
      for (final contact in groupContacts) {
        await app.contacts.add(contact.identity, name: contact.name);
      }
    });
    await tester.pumpWidget(
      appWith(
        ChatsTab(app: app, calls: _CallsWith(chat), groupsEnabled: groups),
      ),
    );
    await settleStore(tester);
  }

  group('with groups off (SOTTO_GROUPS=false)', () {
    testWidgets('no group row, no New group entry and no group screen', (
      tester,
    ) async {
      await seed(tester);
      await pumpTab(tester, groups: false);

      // The one-to-one chat is listed; the group is not.
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Weekend trip'), findsNothing);
      expect(find.text('See you there'), findsNothing);
      expect(find.text('All (1)'), findsOneWidget);

      // New chat goes straight to the contacts, with no New group entry.
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      expect(find.text('New conversation'), findsOneWidget);
      expect(find.text('New group'), findsNothing);
      expect(find.byType(GroupCreatePage), findsNothing);
      expect(find.byType(ChatPage), findsNothing);
    });

    test('the build constant is on unless SOTTO_GROUPS=false', () {
      // The CI and release builds set nothing, so groups are on, and every
      // screen follows the build constant unless told otherwise.
      expect(groupsBuildEnabled, isTrue);
      expect(
        ChatsTab(app: _unusedApp, calls: _CallsWith(chat)).groupsEnabled,
        isTrue,
      );
      expect(StarredPage(chat: chat).groupsEnabled, isTrue);
      expect(
        ChatPage(
          chat: chat,
          contactId: 'g',
          name: 'g',
          groupId: 'g',
        ).groupsEnabled,
        isTrue,
      );
    });

    testWidgets('a starred group message is not listed', (tester) async {
      final group = groupOf(others: [anna, ben]);
      await tester.runAsync(() async {
        await store.saveGroup(group);
        await store.add(
          groupMessage(
            group,
            author: anna,
            text: 'Starred in a group',
          ).copyWith(starred: true),
        );
      });
      await tester.pumpWidget(
        appWith(StarredPage(chat: chat, groupsEnabled: false)),
      );
      await settleStore(tester);
      expect(find.text('Starred in a group'), findsNothing);
    });
  });

  group('with groups on', () {
    testWidgets('a group row shows its name, member count and last sender', (
      tester,
    ) async {
      await seed(tester);
      await pumpTab(tester, groups: true);

      expect(find.text('Weekend trip'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('Anna: See you there'), findsOneWidget);
      // Unread like any chat.
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Weekend trip'),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(find.text('All (2)'), findsOneWidget);
    });

    testWidgets('a group row is pinned, muted and archived like a chat', (
      tester,
    ) async {
      final group = await seed(tester);
      await pumpTab(tester, groups: true);

      Future<void> choose(String item) async {
        await tester.longPress(find.text('Weekend trip'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text(item));
        await settleStore(tester);
      }

      await choose('Pin to top');
      expect(find.text('Pinned'), findsOneWidget);
      await choose('Mute');
      expect(
        (await tester.runAsync(() => store.chatMeta(group.id)))?.muted,
        isTrue,
      );
      await choose('Archive');
      expect(find.text('Archived (1)'), findsOneWidget);
      expect(find.text('Weekend trip'), findsNothing);
    });

    testWidgets('a tap opens the group in the chat page', (tester) async {
      await seed(tester);
      await pumpTab(tester, groups: true);
      await tester.tap(find.text('Weekend trip'));
      await tester.pumpAndSettle();
      await settleStore(tester);
      await settleStore(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Weekend trip'),
        ),
        findsOneWidget,
      );
      // The incoming bubble names its sender.
      expect(find.text('Anna'), findsOneWidget);
    });

    testWidgets('New group is the second entry of the new-chat sheet', (
      tester,
    ) async {
      await pumpTab(tester, groups: true);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      final entries = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(entries, ['New chat', 'New group']);
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupCreatePage), findsOneWidget);
    });

    testWidgets('a starred group message is listed under the group name', (
      tester,
    ) async {
      final group = groupOf(name: 'Weekend trip', others: [anna, ben]);
      await tester.runAsync(() async {
        await store.saveGroup(group);
        await store.add(
          groupMessage(
            group,
            author: anna,
            text: 'Starred in a group',
          ).copyWith(starred: true),
        );
      });
      await tester.pumpWidget(
        appWith(StarredPage(chat: chat, groupsEnabled: true)),
      );
      await settleStore(tester);
      expect(find.text('Starred in a group'), findsOneWidget);
      expect(find.text('Weekend trip'), findsOneWidget);
    });

    testWidgets('an invitation is listed before any message', (tester) async {
      await tester.runAsync(
        () => store.saveGroup(
          groupOf(
            name: 'Book club',
            others: [anna, ben],
            selfState: MemberState.invited,
          ),
        ),
      );
      await pumpTab(tester, groups: true);
      expect(find.text('Book club'), findsOneWidget);
      expect(find.text('Invitation to join'), findsOneWidget);
    });
  });
}

/// An app controller for a widget that is built but never shown.
final AppController _unusedApp = AppController(
  relayUrl: Uri.parse('ws://localhost:1/relay'),
  linkBase: Uri.parse('http://localhost:1/'),
  persistent: false,
  browserStorage: MemoryBrowserStorage(),
  deviceLister: FakeLister.new,
  startCalls: false,
);
