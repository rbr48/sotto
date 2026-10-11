import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/contacts/contact_book.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity.dart';

/// A Sotto ID: 32 bytes of signing key, as base64url.
String memberId(int n) => b64Encode(List<int>.filled(32, n));

/// This device's id in the group tests.
final String selfId = memberId(1);

/// A contact named [name] whose id is [memberId] of [n].
Contact contactOf(String name, int n) => Contact(
  identity: PublicIdentity(
    signKey: Uint8List.fromList(List.filled(32, n)),
    boxKey: Uint8List(32),
  ),
  name: name,
  addedAt: DateTime(2024),
);

/// Anna, Ben, Cy and Dora: the contacts of this device in the tests.
final List<Contact> groupContacts = [
  contactOf('Anna', 2),
  contactOf('Ben', 3),
  contactOf('Cy', 4),
  contactOf('Dora', 5),
];

/// A chat manager with groups on, whose envelopes go into [sent].
ChatManager groupChat({
  required ChatStore store,
  Set<String>? contacts,
  List<({String to, String type})>? sent,
  DateTime Function()? clock,
  bool groupsEnabled = true,
}) {
  final known = contacts ?? {for (final c in groupContacts) c.identity.id};
  return ChatManager(
    myId: selfId,
    store: store,
    isContact: known.contains,
    send: (to, type, body, callId) => sent?.add((to: to, type: type)),
    iceServers: () async => const [],
    hideIp: () => false,
    createRtc: ({required iceServers, required relayOnly}) async =>
        throw StateError('no connection in this test'),
    clock: clock ?? DateTime.now,
    groupsEnabled: groupsEnabled,
  );
}

/// A group named [name] of this device and [others], in the states given
/// ([selfState] for this device, [states] for the others, accepted when not
/// named).
ChatGroup groupOf({
  String? id,
  String name = 'Trip',
  required List<String> others,
  MemberState selfState = MemberState.accepted,
  Map<String, MemberState> states = const {},
  int createdAt = 1700000000000,
}) => ChatGroup(
  id: id ?? ChatFrames.newId(),
  name: name,
  selfId: selfId,
  createdAt: createdAt,
  members: [
    GroupMember(id: selfId, state: selfState, invitedAt: createdAt),
    for (final other in others)
      GroupMember(
        id: other,
        state: states[other] ?? MemberState.accepted,
        invitedAt: createdAt,
      ),
  ],
);

/// A message in [group] by [author], yours when [author] is [selfId].
ChatMessage groupMessage(
  ChatGroup group, {
  required String author,
  required String text,
  int ts = 1700000000000,
  Map<String, ChatState> memberStates = const {},
}) {
  final outgoing = author == selfId;
  return ChatMessage(
    id: ChatFrames.newId(),
    contactId: group.id,
    groupId: group.id,
    authorId: author,
    outgoing: outgoing,
    read: true,
    ts: ts,
    arrivedAt: outgoing ? null : ts,
    text: text,
    state: outgoing ? ChatState.sending : ChatState.received,
    memberStates: memberStates,
  );
}

/// [home] in an app with the app's languages, in English.
Widget appWith(Widget home, {ThemeData? theme}) => MaterialApp(
  theme: theme,
  locale: AppLanguage.english.locale,
  supportedLocales: AppLanguage.supported,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: home,
);

/// Lets the store's reads and writes finish, then draws a frame.
Future<void> settleStore(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
}
