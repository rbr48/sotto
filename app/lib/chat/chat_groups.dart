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
          rune == 0x2028 ||
          rune == 0x2029 ||
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
  /// or a group that is not three or four people. The rules read only the
  /// invite's own fields, never the receiver's clock, so every device keeps or
  /// drops the same invite (D11).
  static GroupInvite validateInvite({
    required String group,
    required String name,
    required List<String> members,
    required int ts,
    required String inviter,
    required String receiver,
  }) {
    if (!ChatFrames.isId(group)) throw const ChatFrameException('malformed');
    if (ts <= 0) throw const ChatFrameException('malformed');
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

  /// Reads an invite body that [from] sent to the device [receiver]. Throws
  /// [ChatFrameException] for one to drop.
  static GroupInvite decodeInvite(
    String text, {
    required String from,
    required String receiver,
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
    );
  }

  /// The relay body of a group envelope: the padded text of [body] (see
  /// [ChatFrames.encodeGroupBody]), under `body`. The envelope type names the
  /// kind of envelope, and the text repeats it as `t`, so a body of another
  /// kind is refused.
  static Map<String, Object?> envelope(String text) => {'body': text};

  /// The text of a relay body, or null when the body has none.
  static String? textOf(Map<String, dynamic> body) {
    final text = body['body'];
    return text is String ? text : null;
  }

  /// Decodes the text of a relay body of [type] (`group.accept`, and so on).
  /// Throws [ChatFrameException] for anything else, or for a text too long.
  static Map<String, dynamic> _envelopeJson(String text, String type) {
    if (utf8.encode(text).length > maxFrameBytes) {
      throw const ChatFrameException('too-large');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const ChatFrameException('malformed');
    }
    if (json is! Map<String, dynamic> || json['t'] != type) {
      throw const ChatFrameException('malformed');
    }
    return json;
  }

  /// The text of a group answer or leave, dated [ts] (`group.accept`,
  /// `group.decline` or `group.leave`).
  static String encodeAnswer(
    GroupStateKind kind, {
    required String group,
    required int ts,
  }) => ChatFrames.encodeGroupBody({
    't': 'group.${kind.name}',
    'group': group,
    'ts': ts,
  });

  /// Reads the text of a group answer of [kind]: its group and its ts.
  static ({String group, int ts}) decodeAnswer(
    String text,
    GroupStateKind kind,
  ) {
    final json = _envelopeJson(text, 'group.${kind.name}');
    final group = json['group'];
    final ts = json['ts'];
    if (!ChatFrames.isId(group) || ts is! int || ts <= 0) {
      throw const ChatFrameException('malformed');
    }
    return (group: group as String, ts: ts);
  }

  /// The text of a message to [group] for the relay (`group.text`). Its id and
  /// ts are the message's own, as a one-to-one relay text carries them.
  static String encodeRelayText({
    required String group,
    required String id,
    required int ts,
    required String text,
  }) => ChatFrames.encodeGroupBody({
    't': 'group.text',
    'group': group,
    'id': id,
    'ts': ts,
    'text': text,
  });

  /// Reads the text of a relay message to a group. The text is cleaned and
  /// checked as a direct message is (see [ChatFrames.decode]).
  static ({String group, String id, int ts, String text}) decodeRelayText(
    String text,
  ) {
    final json = _envelopeJson(text, 'group.text');
    final group = json['group'];
    final id = json['id'];
    final ts = json['ts'];
    final raw = json['text'];
    if (!ChatFrames.isId(group) ||
        !ChatFrames.isId(id) ||
        ts is! int ||
        ts <= 0 ||
        raw is! String) {
      throw const ChatFrameException('malformed');
    }
    final cleaned = ChatFrames.cleanText(raw);
    if (cleaned.isEmpty) throw const ChatFrameException('malformed');
    if (cleaned.runes.length > maxTextChars) {
      throw const ChatFrameException('too-long');
    }
    return (group: group as String, id: id as String, ts: ts, text: cleaned);
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

  /// The invite this device sends [memberId] for [group]. It is dated with that
  /// member's invitedAt, the ts this device judges the member's answer against,
  /// so the sent ts and the judged ts cannot differ (D11). Its members are the
  /// group's members, this device included.
  static GroupInvite inviteFor(ChatGroup group, String memberId) {
    final member = group.memberOf(memberId);
    if (member == null) throw const ChatFrameException('malformed');
    return GroupInvite(
      group: group.id,
      name: group.name,
      members: group.memberIds,
      ts: member.invitedAt,
      inviter: group.selfId,
    );
  }

  /// The group a receiver holds from [invite]. The inviter is accepted, and
  /// every other member, [selfId] included, is invited at the invite's ts. The
  /// invite is checked again here (D24): a [GroupInvite] can be built without
  /// decoding, so a caller cannot skip the rules.
  static ChatGroup fromInvite(GroupInvite invite, {required String selfId}) {
    final checked = validateInvite(
      group: invite.group,
      name: invite.name,
      members: invite.members,
      ts: invite.ts,
      inviter: invite.inviter,
      receiver: selfId,
    );
    return ChatGroup(
      id: checked.group,
      name: checked.name,
      selfId: selfId,
      createdAt: checked.ts,
      members: [
        for (final id in checked.members)
          GroupMember(
            id: id,
            state: id == checked.inviter
                ? MemberState.accepted
                : MemberState.invited,
            invitedAt: checked.ts,
          ),
      ],
    );
  }

  /// Whether an answer made at [answeredAt] falls in the window of an invite
  /// dated [invitedAt] (D11). The window runs [inviteWindow] from the invite's
  /// ts. The answering device's clock may run behind or ahead of the inviter's
  /// by up to [clockSkew], so each end of the window is widened by that. Only
  /// the two ts values count, never the time of arrival, so every device gives
  /// the same answer.
  static bool inWindow(int invitedAt, int answeredAt) {
    final skew = clockSkew.inMilliseconds;
    return answeredAt >= invitedAt - skew &&
        answeredAt <= invitedAt + inviteWindow.inMilliseconds + skew;
  }

  /// Sets the state of [memberId] to [to] when the member is in [from], and
  /// leaves the group as it is otherwise.
  static ChatGroup _set(
    ChatGroup group,
    String memberId,
    Set<MemberState> from,
    MemberState to, {
    int? invitedAt,
  }) {
    final member = group.memberOf(memberId);
    if (member == null || !from.contains(member.state)) return group;
    return group.withMember(
      GroupMember(
        id: memberId,
        state: to,
        invitedAt: invitedAt ?? member.invitedAt,
      ),
    );
  }

  /// An accept from [memberId], made at [ts]. An invited or expired member is
  /// accepted when the accept falls in the window (D11), and expired when it
  /// does not. A member who has declined, accepted or left does not change.
  static ChatGroup accept(ChatGroup group, String memberId, int ts) {
    final member = group.memberOf(memberId);
    if (member == null) return group;
    final answered = inWindow(member.invitedAt, ts)
        ? MemberState.accepted
        : MemberState.expired;
    return _set(group, memberId, {
      MemberState.invited,
      MemberState.expired,
    }, answered);
  }

  /// A decline from [memberId]. It is final: the member stays declined until a
  /// new invite (D23). A member who has accepted or left does not change.
  static ChatGroup decline(ChatGroup group, String memberId) => _set(
    group,
    memberId,
    {MemberState.invited, MemberState.expired},
    MemberState.declined,
  );

  /// A new invite to [memberId], dated [ts], after a decline or an expiry
  /// (D23). It counts only when [ts] is later than the invite it answers, so a
  /// resent copy of that invite, or an older one, leaves the member as it is.
  /// Any other state does not change.
  static ChatGroup reinvite(ChatGroup group, String memberId, int ts) {
    final member = group.memberOf(memberId);
    if (member == null || ts <= member.invitedAt) return group;
    return _set(
      group,
      memberId,
      {MemberState.declined, MemberState.expired},
      MemberState.invited,
      invitedAt: ts,
    );
  }

  /// Applies a group answer of [kind] from [memberId], dated [ts], to [group]
  /// (see [accept], [decline] and [leave]). A decline dated before the invite
  /// it would answer belongs to an earlier invite, so it does not count.
  static ChatGroup applyAnswer(
    ChatGroup group,
    String memberId,
    GroupStateKind kind,
    int ts,
  ) {
    final member = group.memberOf(memberId);
    if (member == null) return group;
    return switch (kind) {
      GroupStateKind.accept => accept(group, memberId, ts),
      GroupStateKind.decline when ts < member.invitedAt => group,
      GroupStateKind.decline => decline(group, memberId),
      GroupStateKind.leave => leave(group, memberId),
    };
  }

  /// A new invite to [memberId] as the other members learn of it, dated [ts]:
  /// a member who has not answered yet, or has declined or let an invite
  /// expire, starts a new window from [ts] (see [reinvite]). An accepted or a
  /// left member does not change, and nor does a ts that is not later than the
  /// invite it would replace.
  static ChatGroup renew(ChatGroup group, String memberId, int ts) {
    final member = group.memberOf(memberId);
    if (member == null || ts <= member.invitedAt) return group;
    if (member.state != MemberState.invited) {
      return reinvite(group, memberId, ts);
    }
    return _set(
      group,
      memberId,
      {MemberState.invited},
      MemberState.invited,
      invitedAt: ts,
    );
  }

  /// The text of a new invite to [member] of [group], dated [ts], that the
  /// inviter sends to the other members (`group.reinvite`).
  static String encodeRenewal({
    required String group,
    required String member,
    required int ts,
  }) => ChatFrames.encodeGroupBody({
    't': 'group.reinvite',
    'group': group,
    'member': member,
    'ts': ts,
  });

  /// Reads the text of a new invite to a member, as [encodeRenewal] writes it.
  static ({String group, String member, int ts}) decodeRenewal(String text) {
    final json = _envelopeJson(text, 'group.reinvite');
    final group = json['group'];
    final member = json['member'];
    final ts = json['ts'];
    if (!ChatFrames.isId(group) || !isMemberId(member) || ts is! int) {
      throw const ChatFrameException('malformed');
    }
    if (ts <= 0) throw const ChatFrameException('malformed');
    return (group: group as String, member: member as String, ts: ts);
  }

  /// A member who has accepted leaves. Any other state does not change.
  static ChatGroup leave(ChatGroup group, String memberId) =>
      _set(group, memberId, {MemberState.accepted}, MemberState.left);

  /// Marks an invite with no answer by the end of its window as expired. A
  /// device calls this from its own clock, so the result only shows on screen:
  /// an accept that is in the window still joins the member (see [accept]).
  /// Because a join is judged by ts alone, devices agree whatever their clocks
  /// read.
  static ChatGroup expire(ChatGroup group, String memberId) =>
      _set(group, memberId, {MemberState.invited}, MemberState.expired);

  /// Whether this device is in [group]: it accepted and has not left. A group
  /// of two stays active after the other one leaves (D13).
  static bool isActive(ChatGroup group) =>
      group.memberOf(group.selfId)?.state == MemberState.accepted;

  /// The members a message to [group] goes to: the accepted members other than
  /// this device that are still contacts of this device. A member who is no
  /// longer a contact keeps its place in the group but gets nothing further
  /// (D22). Nothing is sent while this device is not active.
  static List<String> sendTargets(ChatGroup group, Set<String> contacts) {
    if (!isActive(group)) return const [];
    return [
      for (final member in group.members)
        if (member.id != group.selfId &&
            member.state == MemberState.accepted &&
            contacts.contains(member.id))
          member.id,
    ];
  }

  /// The other members that are not contacts of this device. A device that is
  /// missing one cannot join, and says so on its own screen only (D3).
  static List<String> missingContacts(
    ChatGroup group,
    Set<String> contacts,
  ) => [
    for (final member in group.members)
      if (member.id != group.selfId && !contacts.contains(member.id)) member.id,
  ];

  /// Whether a reply in a group may quote a message by [authorId]: only the
  /// replier's own message (D25). A receiver cannot check another member's
  /// text, so a quote of it could carry words the receiver never saw.
  static bool mayQuote({required String authorId, required String replierId}) =>
      authorId == replierId;
}
