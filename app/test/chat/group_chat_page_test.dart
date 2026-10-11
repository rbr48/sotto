import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/chat_page.dart';
import 'package:sotto/contacts/contact_book.dart';
import 'package:sotto/crypto/identity_store.dart';

import 'support/group_fixtures.dart';

void main() {
  late ChatStore store;
  late ChatManager chat;
  late List<({String to, String type})> sent;
  final anna = memberId(2);
  final ben = memberId(3);
  final now = DateTime(2026, 10, 9, 12);
  final nowMs = now.millisecondsSinceEpoch;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    sent = [];
    chat = groupChat(store: store, sent: sent, clock: () => now);
  });

  /// Opens [group] in the chat page, with [messages] in it and Anna, Ben, Cy
  /// and Dora as contacts.
  Future<void> pumpGroup(
    WidgetTester tester,
    ChatGroup group, {
    List<ChatMessage> messages = const [],
  }) async {
    final book = ContactBook(MemorySecretStore());
    await tester.runAsync(() async {
      for (final contact in groupContacts) {
        await book.add(contact.identity, name: contact.name);
      }
      await store.saveGroup(group);
      for (final message in messages) {
        await store.add(message);
      }
    });
    await tester.pumpWidget(
      appWith(
        ChatPage(
          chat: chat,
          contactId: group.id,
          name: group.name,
          groupId: group.id,
          groupsEnabled: true,
          contacts: book,
        ),
      ),
    );
    await settleStore(tester);
    await settleStore(tester);
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(chat.dispose);
  }

  Future<void> openMenu(WidgetTester tester, String body) async {
    await tester.longPress(find.text(body));
    await tester.pumpAndSettle();
  }

  testWidgets('the header shows the group name and how many are in it', (
    tester,
  ) async {
    await pumpGroup(tester, groupOf(name: 'Weekend trip', others: [anna, ben]));
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Weekend trip'),
      ),
      findsOneWidget,
    );
    expect(find.text('3 members'), findsOneWidget);
    // No call buttons and no voice message in a group.
    expect(find.byIcon(Icons.call), findsNothing);
    expect(find.byIcon(Icons.videocam), findsNothing);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.byIcon(Icons.attach_file), findsNothing);
    await leave(tester);
  });

  testWidgets('an incoming bubble names its sender', (tester) async {
    final group = groupOf(others: [anna, ben]);
    await pumpGroup(
      tester,
      group,
      messages: [
        groupMessage(group, author: anna, text: 'From Anna', ts: nowMs - 3000),
        groupMessage(group, author: ben, text: 'From Ben', ts: nowMs - 2000),
      ],
    );
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('your message says Delivered to all once every member has it', (
    tester,
  ) async {
    final group = groupOf(others: [anna, ben]);
    await pumpGroup(
      tester,
      group,
      messages: [
        groupMessage(
          group,
          author: selfId,
          text: 'Everyone has this',
          ts: nowMs - 5000,
          memberStates: {anna: ChatState.delivered, ben: ChatState.delivered},
        ),
        groupMessage(
          group,
          author: selfId,
          text: 'Only Anna has this',
          ts: nowMs - 4000,
          memberStates: {anna: ChatState.read, ben: ChatState.sending},
        ),
      ],
    );
    expect(find.text('Delivered to all'), findsOneWidget);
    expect(find.text('Sent to 1 of 2'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('the info of your message lists each member', (tester) async {
    final group = groupOf(others: [anna, ben]);
    await pumpGroup(
      tester,
      group,
      messages: [
        groupMessage(
          group,
          author: selfId,
          text: 'Check this',
          ts: nowMs - 5000,
          memberStates: {anna: ChatState.read, ben: ChatState.sending},
        ),
      ],
    );
    await openMenu(tester, 'Check this');
    await tester.tap(find.text('Message info'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('Anna')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Read')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Ben')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Sending')),
      findsOneWidget,
    );
    await leave(tester);
  });

  testWidgets(
    'Reply is offered on your message, never on another member\'s (D25)',
    (tester) async {
      final group = groupOf(others: [anna, ben]);
      await pumpGroup(
        tester,
        group,
        messages: [
          groupMessage(
            group,
            author: anna,
            text: 'Anna wrote',
            ts: nowMs - 5000,
          ),
          groupMessage(
            group,
            author: selfId,
            text: 'I wrote',
            ts: nowMs - 4000,
          ),
        ],
      );
      await openMenu(tester, 'Anna wrote');
      expect(find.text('React'), findsOneWidget);
      expect(find.text('Reply'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await openMenu(tester, 'I wrote');
      expect(find.text('Reply'), findsOneWidget);
      await leave(tester);
    },
  );

  testWidgets('a text sent here goes through the group manager', (
    tester,
  ) async {
    final group = groupOf(others: [anna, ben]);
    await pumpGroup(tester, group);
    await tester.enterText(find.byType(TextField), 'Hello all');
    await tester.tap(find.byIcon(Icons.send));
    await settleStore(tester);
    await settleStore(tester);
    expect(find.text('Hello all'), findsOneWidget);
    // No member has a session, so each gets a relay copy.
    expect(sent.where((s) => s.type == 'group.text').map((s) => s.to).toSet(), {
      anna,
      ben,
    });
    await tester.runAsync(() async {
      final stored = await store.messages(group.id);
      expect(stored.single.authorId, selfId);
      expect(stored.single.memberStates.keys.toSet(), {anna, ben});
    });
    await leave(tester);
  });

  testWidgets('an invitation shows Accept and Decline; Accept joins', (
    tester,
  ) async {
    final group = groupOf(
      others: [anna, ben],
      selfState: MemberState.invited,
      createdAt: nowMs - 1000,
    );
    await pumpGroup(tester, group);
    expect(find.text('You are invited to this group.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Accept'));
    await settleStore(tester);
    await settleStore(tester);
    await tester.runAsync(() async {
      expect(
        (await store.group(group.id))!.memberOf(selfId)!.state,
        MemberState.accepted,
      );
    });
    expect(
      sent.where((s) => s.type == 'group.accept').map((s) => s.to).toSet(),
      {anna, ben},
    );
    // In now: the composer takes the place of the invitation.
    expect(find.text('Accept'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await leave(tester);
  });

  testWidgets('Decline goes through the group manager, and is final', (
    tester,
  ) async {
    final group = groupOf(
      others: [anna, ben],
      selfState: MemberState.invited,
      createdAt: nowMs - 1000,
    );
    await pumpGroup(tester, group);
    await tester.tap(find.text('Decline'));
    await settleStore(tester);
    await settleStore(tester);
    await tester.runAsync(() async {
      expect(
        (await store.group(group.id))!.memberOf(selfId)!.state,
        MemberState.declined,
      );
    });
    expect(
      sent.where((s) => s.type == 'group.decline').map((s) => s.to).toSet(),
      {anna, ben},
    );
    expect(find.text('You declined this invitation.'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await leave(tester);
  });

  testWidgets('an invite with a member who is not your contact is refused '
      'here, and says so', (tester) async {
    final stranger = memberId(9);
    final group = groupOf(
      others: [anna, stranger],
      selfState: MemberState.invited,
      createdAt: nowMs - 1000,
    );
    await pumpGroup(tester, group);
    await tester.tap(find.text('Accept'));
    await settleStore(tester);
    expect(
      find.text("You can't join: not every member is one of your contacts."),
      findsOneWidget,
    );
    expect(sent, isEmpty);
    await leave(tester);
  });

  testWidgets('a group you left is read-only, with its history', (
    tester,
  ) async {
    final group = groupOf(others: [anna, ben], selfState: MemberState.left);
    await pumpGroup(
      tester,
      group,
      messages: [
        groupMessage(
          group,
          author: anna,
          text: 'Before you left',
          ts: nowMs - 5000,
        ),
        groupMessage(
          group,
          author: selfId,
          text: 'My last word',
          ts: nowMs - 4000,
        ),
      ],
    );
    expect(find.text('Before you left'), findsOneWidget);
    expect(
      find.text('You left this group. Its messages stay on this device.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    // Nothing that would reach the members: no react, reply, edit or delete
    // for everyone.
    await openMenu(tester, 'My last word');
    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('React'), findsNothing);
    expect(find.text('Reply'), findsNothing);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
    await leave(tester);
  });

  testWidgets('the info button opens the members and Leave group', (
    tester,
  ) async {
    await pumpGroup(
      tester,
      groupOf(others: [anna, ben], states: {ben: MemberState.left}),
    );
    await tester.tap(find.byTooltip('Group info'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('Left')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Leave group')),
      findsOneWidget,
    );
    await leave(tester);
  });

  testWidgets('react, edit and delete for everyone go to every member', (
    tester,
  ) async {
    final group = groupOf(others: [anna, ben]);
    final theirs = groupMessage(
      group,
      author: anna,
      text: 'Anna asks',
      ts: nowMs - 60000,
    );
    final mine = groupMessage(
      group,
      author: selfId,
      text: 'Typo here',
      ts: nowMs - 60000,
      memberStates: {anna: ChatState.delivered, ben: ChatState.delivered},
    );
    await pumpGroup(tester, group, messages: [theirs, mine]);

    await openMenu(tester, 'Anna asks');
    await tester.tap(find.text('React'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍').first);
    // The reaction is queued for each member in turn: let every write finish
    // before reading the store from outside the test's clock.
    for (var i = 0; i < 4; i++) {
      await settleStore(tester);
    }
    await tester.runAsync(() async {
      expect((await store.find(group.id, theirs.id))!.reactions, {
        selfId: '👍',
      });
    });

    await openMenu(tester, 'Typo here');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Fixed here');
    await tester.tap(find.byIcon(Icons.send));
    await settleStore(tester);
    await settleStore(tester);
    expect(find.text('Fixed here'), findsOneWidget);
    await tester.runAsync(() async {
      final edited = (await store.find(group.id, mine.id))!;
      expect(edited.text, 'Fixed here');
      expect(edited.editedAt, isNotNull);
    });

    await openMenu(tester, 'Fixed here');
    await tester.tap(find.text('Delete for everyone'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete for everyone'));
    await settleStore(tester);
    await settleStore(tester);
    await tester.runAsync(() async {
      expect((await store.find(group.id, mine.id))!.deletedForAll, isTrue);
    });
    await leave(tester);
  });
}
