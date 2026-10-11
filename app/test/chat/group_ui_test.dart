import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/group_ui.dart';
import 'package:sotto/core/l10n/app_localizations_en.dart';

import 'support/group_fixtures.dart';

void main() {
  final l10n = AppLocalizationsEn();
  final anna = memberId(2);
  final ben = memberId(3);
  final cy = memberId(4);

  group('the delivery of your group message', () {
    final group = groupOf(others: [anna, ben, cy]);
    bool everyone(String _) => true;

    test('every active member stored it: Delivered to all', () {
      final message = groupMessage(
        group,
        author: selfId,
        text: 'hi',
        memberStates: {
          anna: ChatState.delivered,
          ben: ChatState.delivered,
          cy: ChatState.read,
        },
      );
      final delivery = groupDelivery(message, group, everyone)!;
      expect(delivery.kind, GroupDeliveryKind.deliveredToAll);
      expect(groupDeliveryText(l10n, delivery), 'Delivered to all');
    });

    test('some have not: Sent to X of Y, a read counting as delivered', () {
      final message = groupMessage(
        group,
        author: selfId,
        text: 'hi',
        memberStates: {
          anna: ChatState.read,
          ben: ChatState.sending,
          cy: ChatState.notSent,
        },
      );
      final delivery = groupDelivery(message, group, everyone)!;
      expect(delivery.kind, GroupDeliveryKind.partial);
      expect((delivery.delivered, delivery.total), (1, 3));
      expect(groupDeliveryText(l10n, delivery), 'Sent to 1 of 3');
    });

    test('every active member read it: Read by all', () {
      final message = groupMessage(
        group,
        author: selfId,
        text: 'hi',
        memberStates: {anna: ChatState.read, ben: ChatState.read},
      );
      expect(
        groupDeliveryText(l10n, groupDelivery(message, group, everyone)!),
        'Read by all',
      );
    });

    test('a member who left, or is not a contact, is not counted', () {
      final left = groupOf(
        others: [anna, ben, cy],
        states: {ben: MemberState.left},
      );
      final message = groupMessage(
        left,
        author: selfId,
        text: 'hi',
        memberStates: {
          anna: ChatState.delivered,
          ben: ChatState.sending,
          cy: ChatState.sending,
        },
      );
      final delivery = groupDelivery(message, left, (id) => id != cy)!;
      expect(delivery.kind, GroupDeliveryKind.deliveredToAll);
      expect(delivery.total, 1);
    });

    test('a member who joined after the message is not counted', () {
      final message = groupMessage(
        group,
        author: selfId,
        text: 'hi',
        memberStates: {anna: ChatState.delivered},
      );
      expect(groupDelivery(message, group, everyone)!.total, 1);
    });

    test('a message by another member has no delivery summary', () {
      final message = groupMessage(group, author: anna, text: 'hi');
      expect(groupDelivery(message, group, everyone), isNull);
    });

    test('a message sent to no one still active has none either', () {
      final message = groupMessage(group, author: selfId, text: 'hi');
      expect(groupDelivery(message, group, everyone), isNull);
    });
  });

  group('the members', () {
    test(
      'each state has its own words, and a non-contact is not reachable',
      () {
        final group = groupOf(
          others: [anna, ben, cy, memberId(5)],
          states: {
            ben: MemberState.declined,
            cy: MemberState.expired,
            memberId(5): MemberState.invited,
          },
        );
        String status(String id) => groupMemberStatusText(
          l10n,
          groupMemberStatus(group, group.memberOf(id)!, (m) => m != anna),
        );
        expect(status(selfId), 'Joined');
        expect(status(anna), 'Not reachable');
        expect(status(ben), 'Declined');
        expect(status(cy), 'No answer');
        expect(status(memberId(5)), 'Invited');
      },
    );

    test('a member who left is shown as left, contact or not', () {
      final group = groupOf(others: [anna], states: {anna: MemberState.left});
      expect(
        groupMemberStatus(group, group.memberOf(anna)!, (_) => false),
        GroupMemberStatus.left,
      );
    });

    test('the count leaves out those who declined or left', () {
      final group = groupOf(
        others: [anna, ben, cy],
        states: {ben: MemberState.declined, cy: MemberState.left},
      );
      expect(groupMemberCount(group), 2);
    });

    test('a member who is not a contact is named by a short id', () {
      expect(groupMemberName(l10n, groupContacts, anna), 'Anna');
      expect(
        groupMemberName(l10n, groupContacts, memberId(9)),
        'Contact ${memberId(9).substring(0, 8)}',
      );
    });
  });
}
