import 'dart:convert';
import 'dart:math';

import '../crypto/encoding.dart';
import 'chat_frames.dart';
import 'chat_group.dart';

/// The longest group name after cleaning, in characters (D12).
const int maxGroupNameChars = 64;

/// How long an invite waits for an answer, measured from its ts (D11).
const Duration inviteWindow = Duration(minutes: 15);

/// The fewest and the most other members an invite names (D24). With the
/// inviter, a group has three or four people.
const int minInviteOthers = 2;
const int maxInviteOthers = 3;

/// An invite as a receiver reads it. [inviter] is the sender of the envelope;
/// [members] includes it and the receiver.
final class GroupInvite {
  const GroupInvite({
    required this.group,
    required this.name,
    required this.members,
    required this.ts,
    required this.inviter,
  });

  final String group;

  /// The name after cleaning.
  final String name;

  final List<String> members;

  /// The inviter's clock, in milliseconds since the Unix epoch.
  final int ts;

  final String inviter;
}

/// The pure rules of groups (`docs/MESSAGING_PLAN.md`, section 4). No I/O.
abstract final class ChatGroups {
  /// A group name after cleaning: control characters, line breaks, direction
  /// overrides and lone surrogates are removed, and the ends are trimmed. A
  /// name is one line, so a line break goes too. Callers check the length.
  static String cleanName(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final dropped =
          rune < 0x20 ||
          (rune >= 0x7F && rune <= 0x9F) ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          (rune >= 0xD800 && rune <= 0xDFFF);
      if (!dropped) buffer.writeCharCode(rune);
    }
    return buffer.toString().trim();
  }

  /// Whether [value] is a Sotto ID: the 32-byte signing key, unpadded
  /// base64url. It is the address a member is reached at.
  static bool isMemberId(Object? value) {
    if (value is! String) return false;
    try {
      return b64Decode(value).length == 32;
    } on FormatException {
      return false;
    }
  }

  /// The cleaned name, or a [ChatFrameException] when it is empty or too long.
  static String _checkedName(String name) {
    final cleaned = cleanName(name);
    if (cleaned.isEmpty) throw const ChatFrameException('malformed');
    if (cleaned.runes.length > maxGroupNameChars) {
      throw const ChatFrameException('too-long');
    }
    return cleaned;
  }

  /// Checks an invite a receiver has read (D24). Throws [ChatFrameException]
  /// for one to drop: a malformed id, name, ts or member list; a member list
  /// without the inviter or the receiver, or with the inviter as the receiver;
  /// or a group that is not three or four people. [nowMs] is the receiver's
  /// clock: an invite dated further ahead than [clockSkew] is not trusted.
  static GroupInvite validateInvite({
    required String group,
    required String name,
    required List<String> members,
    required int ts,
    required String inviter,
    required String receiver,
    required int nowMs,
  }) {
    if (!ChatFrames.isId(group)) throw const ChatFrameException('malformed');
    if (ts <= 0 || ts - nowMs > clockSkew.inMilliseconds) {
      throw const ChatFrameException('malformed');
    }
    final cleaned = _checkedName(name);
    if (members.toSet().length != members.length ||
        !members.every(isMemberId)) {
      throw const ChatFrameException('malformed');
    }
    if (inviter == receiver ||
        !members.contains(inviter) ||
        !members.contains(receiver)) {
      throw const ChatFrameException('malformed');
    }
    final others = members.length - 1;
    if (others < minInviteOthers) throw const ChatFrameException('too-few');
    if (others > maxInviteOthers) throw const ChatFrameException('too-many');
    return GroupInvite(
      group: group,
      name: cleaned,
      members: List.unmodifiable(members),
      ts: ts,
      inviter: inviter,
    );
  }

  /// The body of an invite, padded (D17). The inviter is the sender of the
  /// envelope, so the body does not name it.
  static String encodeInvite(GroupInvite invite) => ChatFrames.encodeGroupBody({
    't': 'group.invite',
    'group': invite.group,
    'name': invite.name,
    'members': invite.members,
    'ts': invite.ts,
  });

  /// Reads an invite body that [from] sent to the device [receiver], whose
  /// clock reads [nowMs]. Throws [ChatFrameException] for one to drop.
  static GroupInvite decodeInvite(
    String text, {
    required String from,
    required String receiver,
    required int nowMs,
  }) {
    if (utf8.encode(text).length > maxFrameBytes) {
      throw const ChatFrameException('too-large');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const ChatFrameException('malformed');
    }
    if (json is! Map<String, dynamic> || json['t'] != 'group.invite') {
      throw const ChatFrameException('malformed');
    }
    final group = json['group'];
    final name = json['name'];
    final ts = json['ts'];
    final rawMembers = json['members'];
    if (group is! String || name is! String || ts is! int) {
      throw const ChatFrameException('malformed');
    }
    if (rawMembers is! List) throw const ChatFrameException('malformed');
    final members = <String>[];
    for (final member in rawMembers) {
      if (member is! String) throw const ChatFrameException('malformed');
      members.add(member);
    }
    return validateInvite(
      group: group,
      name: name,
      members: members,
      ts: ts,
      inviter: from,
      receiver: receiver,
      nowMs: nowMs,
    );
  }

  /// A new group made on this device. [invitees] are two or three other
  /// contacts (D24), each of them one of [contacts]. The creator is accepted,
  /// and each invitee is invited at [ts]. The group id is 16 random bytes.
  static ChatGroup create({
    required String selfId,
    required String name,
    required List<String> invitees,
    required Set<String> contacts,
    required int ts,
    Random? random,
  }) {
    if (!isMemberId(selfId) || ts <= 0) {
      throw const ChatFrameException('malformed');
    }
    final cleaned = _checkedName(name);
    if (invitees.toSet().length != invitees.length ||
        !invitees.every(isMemberId) ||
        invitees.contains(selfId)) {
      throw const ChatFrameException('malformed');
    }
    if (invitees.length < minInviteOthers) {
      throw const ChatFrameException('too-few');
    }
    if (invitees.length > maxInviteOthers) {
      throw const ChatFrameException('too-many');
    }
    if (!invitees.every((id) => contacts.contains(id))) {
      throw const ChatFrameException('not-contact');
    }
    return ChatGroup(
      id: ChatFrames.newId(random),
      name: cleaned,
      selfId: selfId,
      createdAt: ts,
      members: [
        GroupMember(id: selfId, state: MemberState.accepted, invitedAt: ts),
        for (final id in invitees)
          GroupMember(id: id, state: MemberState.invited, invitedAt: ts),
      ],
    );
  }

  /// The invite this device sends for [group], dated [ts]. Its members are the
  /// group's members, this device included.
  static GroupInvite inviteFor(ChatGroup group, {required int ts}) =>
      GroupInvite(
        group: group.id,
        name: group.name,
        members: group.memberIds,
        ts: ts,
        inviter: group.selfId,
      );

  /// The group a receiver holds from [invite]. The inviter is accepted, and
  /// every other member, [selfId] included, is invited at the invite's ts.
  static ChatGroup fromInvite(GroupInvite invite, {required String selfId}) {
    if (!invite.members.contains(selfId)) {
      throw const ChatFrameException('malformed');
    }
    return ChatGroup(
      id: invite.group,
      name: invite.name,
      selfId: selfId,
      createdAt: invite.ts,
      members: [
        for (final id in invite.members)
          GroupMember(
            id: id,
            state: id == invite.inviter
                ? MemberState.accepted
                : MemberState.invited,
            invitedAt: invite.ts,
          ),
      ],
    );
  }
}
