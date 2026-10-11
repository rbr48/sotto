import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/encoding.dart';

/// A Sotto ID: 32 bytes of signing key, as base64url.
String _member(int n) => b64Encode(List<int>.filled(32, n));

/// A group id, or a message id: 16 bytes, as base64url.
String _id(int n) => b64Encode(List<int>.filled(16, n));

/// [message] as it is stored, read back.
ChatMessage _reload(String scope, ChatMessage message) => ChatMessage.fromJson(
  scope,
  jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
);

/// A group message from [author] in [group].
ChatMessage _groupMessage({
  required String group,
  required String author,
  int n = 1,
  bool outgoing = false,
  Map<String, String> reactions = const {},
  Map<String, ChatState> memberStates = const {},
}) => ChatMessage(
  id: _id(n),
  contactId: group,
  groupId: group,
  authorId: author,
  outgoing: outgoing,
  ts: 1700000000000 + n,
  text: 'hello $n',
  state: outgoing ? ChatState.sending : ChatState.received,
  reactions: reactions,
  memberStates: memberStates,
);

/// The JSON of a group message in [group] from [author], as stored.
Map<String, dynamic> _groupJson(String group, String author) => {
  ..._legacyJson(1),
  'groupId': group,
  'authorId': author,
};

/// The JSON of a message as an earlier build stored it: no group fields.
Map<String, dynamic> _legacyJson(int n) => {
  'id': _id(n),
  'out': false,
  'ts': 1700000000000 + n,
  'text': 'old',
  'state': 'received',
  'reason': null,
  'read': false,
};

void main() {
  group('group fields on a message', () {
    final group = _id(90);
    final alice = _member(1);
    final bob = _member(2);

    test('a group message keeps its group, author, member states and member reactions across a reload', () {
      final message = _groupMessage(
        group: group,
        author: alice,
        outgoing: true,
        reactions: {alice: '👍', bob: '🎉'},
        memberStates: {bob: ChatState.delivered, alice: ChatState.sending},
      );
      final again = _reload(group, message);

      expect(again.groupId, group);
      expect(again.contactId, group);
      expect(again.authorId, alice);
      expect(again.reactions, {alice: '👍', bob: '🎉'});
      expect(again.memberStates, {
        bob: ChatState.delivered,
        alice: ChatState.sending,
      });
    });

    test('a record from before groups loads with no group, author or member states', () {
      final message = ChatMessage.fromJson('bob', _legacyJson(1));

      expect(message.groupId, isNull);
      expect(message.authorId, isNull);
      expect(message.memberStates, isEmpty);
      expect(message.toJson().containsKey('groupId'), isFalse);
      expect(message.toJson().containsKey('authorId'), isFalse);
      expect(message.toJson().containsKey('memberStates'), isFalse);
    });

    test('a one-to-one message keeps "me" and "peer" as its reactors, and refuses a member id', () {
      final message = ChatMessage.fromJson('bob', {
        ..._legacyJson(2),
        'reactions': {'me': '👍', 'peer': '🎉'},
      });
      expect(message.reactions, {'me': '👍', 'peer': '🎉'});

      expect(
        () => ChatMessage.fromJson('bob', {
          ..._legacyJson(3),
          'reactions': {alice: '👍'},
        }),
        throwsA(isA<ChatStoreException>()),
      );
    });

    test('a group message refuses "me" and "peer" as its reactors', () {
      for (final reactor in ['me', 'peer']) {
        expect(
          () => ChatMessage.fromJson(group, {
            ..._groupJson(group, alice),
            'reactions': {reactor: '👍'},
          }),
          throwsA(isA<ChatStoreException>()),
          reason: reactor,
        );
      }
    });

    test('a group message with no author, or a member state that is not known, is refused', () {
      final noAuthor = _groupJson(group, alice)..remove('authorId');
      expect(
        () => ChatMessage.fromJson(group, noAuthor),
        throwsA(isA<ChatStoreException>()),
      );
      expect(
        () => ChatMessage.fromJson(group, {
          ..._groupJson(group, alice),
          'memberStates': {bob: 'waiting'},
        }),
        throwsA(isA<ChatStoreException>()),
      );
    });

    test('a group message stored under another group is refused', () {
      expect(
        () => ChatMessage.fromJson(_id(91), _groupJson(group, alice)),
        throwsA(isA<ChatStoreException>()),
      );
      expect(
        () => ChatMessage.fromJson(bob, _groupJson(group, alice)),
        throwsA(isA<ChatStoreException>()),
      );
    });
  });
}
