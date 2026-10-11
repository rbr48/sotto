import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_arrival.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/core/l10n/app_localizations_en.dart';
import 'package:sotto/desktop/notices.dart';

import 'support/group_fixtures.dart';

void main() {
  final anna = memberId(2);
  final stranger = memberId(9);
  final group = groupOf(
    name: 'Secret surprise party',
    others: [anna, stranger],
  );
  String nameOf(String id) => id == anna ? 'Anna' : '';

  ChatUpdate groupArrival(String author) => ChatUpdate(
    group.id,
    MessageReceived(
      groupMessage(group, author: author, text: 'The cake is in the garage'),
    ),
    group: group.id,
  );

  test('a message from a contact is named by that contact', () {
    final arrival = ChatArrival.of(
      ChatUpdate(
        anna,
        MessageReceived(
          ChatMessage(
            id: 'm1',
            contactId: anna,
            outgoing: false,
            ts: 1,
            text: 'hello',
            state: ChatState.received,
          ),
        ),
      ),
      nameOf: nameOf,
      isViewing: (_) => false,
    )!;
    expect(arrival.senderName, 'Anna');
    expect(arrival.viewing, isFalse);
  });

  test('a group message shows the sender name only (D14)', () {
    final arrival = ChatArrival.of(
      groupArrival(anna),
      nameOf: nameOf,
      isViewing: (_) => false,
    )!;
    expect(arrival.senderName, 'Anna');

    final notice = NoticeRules.chatWords(
      kind: ChatNoticeKind.named,
      senderName: arrival.senderName,
      l10n: AppLocalizationsEn(),
    )!;
    expect(notice.title, 'New message from Anna');
    // Neither the group's name nor the text reaches the notice.
    for (final words in [notice.title, notice.body]) {
      expect(words, isNot(contains('Secret surprise party')));
      expect(words, isNot(contains('cake')));
    }
  });

  test('a group message from someone who is not a contact names no one', () {
    final arrival = ChatArrival.of(
      groupArrival(stranger),
      nameOf: nameOf,
      isViewing: (_) => false,
    )!;
    expect(arrival.senderName, isEmpty);
    final notice = NoticeRules.chatWords(
      kind: ChatNoticeKind.named,
      senderName: arrival.senderName,
      l10n: AppLocalizationsEn(),
    )!;
    expect(notice.title, 'New message');
  });

  test('a group open on screen counts as viewed', () {
    final arrival = ChatArrival.of(
      groupArrival(anna),
      nameOf: nameOf,
      isViewing: (scope) => scope == group.id,
    )!;
    expect(arrival.viewing, isTrue);
  });

  test('other events are no arrival', () {
    expect(
      ChatArrival.of(
        ChatUpdate(group.id, const MessageChanged('m1'), group: group.id),
        nameOf: nameOf,
        isViewing: (_) => false,
      ),
      isNull,
    );
  });
}
