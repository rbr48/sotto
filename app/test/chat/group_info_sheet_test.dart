import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/group_info_sheet.dart';
import 'package:sotto/crypto/identity_store.dart';

import 'support/group_fixtures.dart';

void main() {
  late ChatStore store;
  late ChatManager chat;
  late List<({String to, String type})> sent;
  final anna = memberId(2);
  final ben = memberId(3);
  final cy = memberId(4);
  final stranger = memberId(9);

  setUp(() {
    store = ChatStore(MemorySecretStore());
    sent = [];
    chat = groupChat(store: store, sent: sent);
  });

  tearDown(() async {
    await chat.dispose();
  });

  Future<void> openSheet(WidgetTester tester, ChatGroup group) async {
    await tester.runAsync(() => store.saveGroup(group));
    await tester.pumpWidget(
      appWith(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showGroupInfo(
                  context,
                  chat: chat,
                  group: group,
                  contacts: groupContacts,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every member with where each stands', (tester) async {
    await openSheet(
      tester,
      groupOf(
        others: [anna, ben, cy, stranger],
        states: {ben: MemberState.left, cy: MemberState.invited},
      ),
    );
    expect(find.text('Trip'), findsOneWidget);
    // Anna, Cy, the stranger and you: Ben left.
    expect(find.text('4 members'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'You'), findsOneWidget);
    String statusOf(String name) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.widgetWithText(ListTile, name),
                matching: find.byType(Text),
              )
              .last,
        )
        .data!;
    expect(statusOf('Anna'), 'Joined');
    expect(statusOf('Ben'), 'Left');
    expect(statusOf('Cy'), 'Invited');
    // Not a contact here: named by a short id, and not reachable.
    expect(statusOf('Contact ${stranger.substring(0, 8)}'), 'Not reachable');
  });

  testWidgets('leaving asks first, and a cancel changes nothing', (
    tester,
  ) async {
    final group = groupOf(others: [anna, ben]);
    await openSheet(tester, group);
    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this group?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect((await store.group(group.id))!.left, isFalse);
    });
    expect(sent, isEmpty);
  });

  testWidgets('a confirmed leave goes through the group manager', (
    tester,
  ) async {
    final group = groupOf(others: [anna, ben]);
    await openSheet(tester, group);
    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Leave group'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect((await store.group(group.id))!.left, isTrue);
    });
    expect(
      sent.where((s) => s.type == 'group.leave').map((s) => s.to).toSet(),
      {anna, ben},
    );
    // The sheet closes once you have left.
    expect(find.text('Leave group'), findsNothing);
  });

  testWidgets('a group you are not in has no Leave', (tester) async {
    await openSheet(
      tester,
      groupOf(others: [anna, ben], selfState: MemberState.left),
    );
    expect(find.text('Leave group'), findsNothing);
  });

  testWidgets('a member who declined can be invited again', (tester) async {
    final group = groupOf(
      others: [anna, ben],
      states: {ben: MemberState.declined},
    );
    await openSheet(tester, group);
    expect(find.text('Invite again'), findsOneWidget);
    await tester.tap(find.text('Invite again'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(
        (await store.group(group.id))!.memberOf(ben)!.state,
        MemberState.invited,
      );
    });
    expect(sent.where((s) => s.type == 'group.invite').single.to, ben);
  });
}
