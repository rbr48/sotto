import 'dart:math' as math;

import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../chat_group.dart';
import '../chat_store.dart';

/// Where a member of a group stands, as this device shows it.
enum GroupMemberStatus {
  /// Accepted, and still a contact of this device.
  joined,

  /// Invited, with no answer yet.
  invited,

  /// Declined the invite (final until a new one, D23).
  declined,

  /// Left the group.
  left,

  /// Did not answer within the invite's window.
  noAnswer,

  /// No longer a contact of this device, so it gets nothing from here (D22).
  notReachable,
}

/// The status of [member] in [group] on this device. A member that is not a
/// contact is not reachable, whatever its answer, unless it declined or left.
GroupMemberStatus groupMemberStatus(
  ChatGroup group,
  GroupMember member,
  bool Function(String id) isContact,
) {
  switch (member.state) {
    case MemberState.left:
      return GroupMemberStatus.left;
    case MemberState.declined:
      return GroupMemberStatus.declined;
    case MemberState.invited || MemberState.expired || MemberState.accepted
        when member.id != group.selfId && !isContact(member.id):
      return GroupMemberStatus.notReachable;
    case MemberState.invited:
      return GroupMemberStatus.invited;
    case MemberState.expired:
      return GroupMemberStatus.noAnswer;
    case MemberState.accepted:
      return GroupMemberStatus.joined;
  }
}

/// [status] in words.
String groupMemberStatusText(AppLocalizations l10n, GroupMemberStatus status) =>
    switch (status) {
      GroupMemberStatus.joined => l10n.groupMemberJoined,
      GroupMemberStatus.invited => l10n.groupMemberInvited,
      GroupMemberStatus.declined => l10n.groupMemberDeclined,
      GroupMemberStatus.left => l10n.groupMemberLeft,
      GroupMemberStatus.noAnswer => l10n.groupMemberNoAnswer,
      GroupMemberStatus.notReachable => l10n.groupMemberNotReachable,
    };

/// The people a group counts as members: everyone, this device included,
/// except those who declined or left.
int groupMemberCount(ChatGroup group) => group.members
    .where(
      (m) => m.state != MemberState.left && m.state != MemberState.declined,
    )
    .length;

/// The name this device shows for the member [id]: the contact's name, or a
/// short form of the id for someone who is not a contact.
String groupMemberName(
  AppLocalizations l10n,
  List<Contact> contacts,
  String id,
) {
  for (final contact in contacts) {
    if (contact.identity.id == id) return contact.name;
  }
  return l10n.chatsUnknownContact(id.substring(0, math.min(8, id.length)));
}

/// How far one of your group messages has gone.
enum GroupDeliveryKind {
  /// Every active member has read it.
  readByAll,

  /// Every active member has stored it.
  deliveredToAll,

  /// Some active members have not stored it yet.
  partial,
}

/// The delivery of your group [message] to the members of [group] that are
/// active now: accepted, not this device, and still a contact. A member that
/// joined after the message was sent is not counted, nor is one that left.
/// [delivered] counts the members that acknowledged it; a read counts as
/// delivered. Only the author of a message gets its read receipts, so this
/// is all the device knows. Null for a message that is not yours, not in a
/// group, deleted for everyone, or sent to no one who is still active.
({GroupDeliveryKind kind, int delivered, int total})? groupDelivery(
  ChatMessage message,
  ChatGroup group,
  bool Function(String id) isContact,
) {
  if (!message.outgoing || message.groupId == null || message.deletedForAll) {
    return null;
  }
  final states = [
    for (final entry in message.memberStates.entries)
      if (entry.key != group.selfId &&
          group.memberOf(entry.key)?.state == MemberState.accepted &&
          isContact(entry.key))
        entry.value,
  ];
  if (states.isEmpty) return null;
  final read = states.where((s) => s == ChatState.read).length;
  final delivered = states
      .where((s) => s == ChatState.delivered || s == ChatState.read)
      .length;
  final kind = read == states.length
      ? GroupDeliveryKind.readByAll
      : delivered == states.length
      ? GroupDeliveryKind.deliveredToAll
      : GroupDeliveryKind.partial;
  return (kind: kind, delivered: delivered, total: states.length);
}

/// The delivery of a group message in words: "Read by all", "Delivered to
/// all", or "Sent to X of Y".
String groupDeliveryText(
  AppLocalizations l10n,
  ({GroupDeliveryKind kind, int delivered, int total}) delivery,
) => switch (delivery.kind) {
  GroupDeliveryKind.readByAll => l10n.groupReadAll,
  GroupDeliveryKind.deliveredToAll => l10n.groupDeliveredAll,
  GroupDeliveryKind.partial => l10n.groupSentToSome(
    delivery.delivered,
    delivery.total,
  ),
};
