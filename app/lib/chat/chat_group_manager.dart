import 'chat_frames.dart';
import 'chat_group.dart';
import 'chat_groups.dart';
import 'chat_session.dart';
import 'chat_store.dart';

/// Sends an envelope of [type] to [to] through the relay, as `ChatManager`
/// does for its own.
typedef GroupEnvelopeSend = void Function(
  String to,
  String type,
  Map<String, Object?> body,
  String? callId,
);

/// Reports a change in the group [scope] (a group id) or in a chat.
typedef GroupEmit = void Function(
  String scope,
  ChatSessionEvent event, {
  String? group,
});

/// How often an invite, an accept or a decline is sent again through the
/// relay, while the app is open.
const Duration groupResendEvery = Duration(seconds: 30);

/// How long a text to a group is sent through the relay, from its own ts,
/// before the members that still have not acknowledged it are marked not sent.
const Duration groupRelayWindow = Duration(minutes: 15);

/// At most this many relay texts for groups go out per tick.
const int maxGroupRelayPerTick = 20;

/// The result of accepting an invite.
enum GroupJoinResult {
  /// This device is in the group now.
  joined,

  /// A member is not a contact of this device, so the group cannot be joined
  /// here (D3). See [ChatGroups.missingContacts].
  missingContacts,

  /// The invite is not waiting for an answer.
  notInvited,

  /// The answer came after the window of the invite (D11).
  expired,
}

/// The relay envelope type of an acknowledgement of a text. It is the same
/// type a one-to-one text is acknowledged with; a group acknowledgement names
/// its group.
const String _textAckType = 'chat.text.ack';

/// A group envelope that is sent again through the relay until [until].
class _Resend {
  _Resend({
    required this.to,
    required this.type,
    required this.body,
    required this.until,
    required this.nextAt,
  });

  final String to;
  final String type;
  final Map<String, Object?> body;
  final int until;
  int nextAt;
}

/// Runs the groups of this device: creates them, invites, answers and leaves,
/// sends and changes their messages, and takes what the relay and the member
/// sessions bring. The membership rules are in [ChatGroups]; this class does
/// the I/O around them.
///
/// Every operation needs groups on (see [groupsEnabled]). With them off, a
/// group envelope is ignored and no group envelope is sent.
class ChatGroupManager {
  ChatGroupManager({
    required this.myId,
    required this.store,
    required this.isContact,
    required this.send,
    required this.clock,
    required this.newId,
    required this.sessionOf,
    required this.emit,
    required this.groupsEnabled,
  });

  final String myId;
  final ChatStore store;

  /// Whether a Sotto ID is a contact of this device (D3, D22).
  final bool Function(String contactId) isContact;

  final GroupEnvelopeSend send;
  final DateTime Function() clock;
  final String Function() newId;

  /// The live session with [member], or null when there is none.
  final ChatSession? Function(String member) sessionOf;

  final GroupEmit emit;

  /// Whether groups are on (see `ChatManager.groupsEnabled`).
  final bool groupsEnabled;

  /// Answers (accept and decline) still being sent through the relay.
  final _resends = <_Resend>[];

  int get _now => clock().millisecondsSinceEpoch;

  void _requireGroups() {
    if (!groupsEnabled) throw StateError('groups are off');
  }

  Future<ChatGroup> _group(String groupId) async {
    final group = await store.group(groupId);
    if (group == null) {
      throw ArgumentError.value(groupId, 'groupId', 'is not a group here');
    }
    return group;
  }

  /// The members a message goes to: accepted members that are contacts (D22).
  List<String> _targets(ChatGroup group) => ChatGroups.sendTargets(group, {
    for (final id in group.memberIds)
      if (isContact(id)) id,
  });

  Future<void> _flushMember(String member) async {
    await sessionOf(member)?.flushControls();
  }

  // Creating and inviting.

  /// Makes a group with [name] among [invitees] (two or three contacts, D24),
  /// and invites each of them. Throws [ArgumentError] for a group that cannot
  /// be made, and says why in the message.
  Future<ChatGroup> create({
    required String name,
    required List<String> invitees,
  }) async {
    _requireGroups();
    final ts = _now;
    final ChatGroup group;
    try {
      group = ChatGroups.create(
        selfId: myId,
        name: name,
        invitees: invitees,
        contacts: {
          for (final id in invitees)
            if (isContact(id)) id,
        },
        ts: ts,
      );
    } on ChatFrameException catch (e) {
      throw ArgumentError.value(invitees, 'invitees', e.reason);
    }
    await store.saveGroup(group);
    for (final id in invitees) {
      await _invite(group, id);
    }
    emit(group.id, GroupStateChanged(group.id), group: group.id);
    return group;
  }

  /// Invites [memberId] to the group [groupId] again: after a decline or an
  /// expiry (D23), or to resend an invite still waiting. The other members are
  /// told of the new invite, so their table of the member starts the same
  /// window (see [ChatGroups.renew]). Only a member of the group can invite.
  Future<void> invite(String groupId, String memberId) async {
    _requireGroups();
    final group = await _group(groupId);
    if (!ChatGroups.isActive(group)) {
      throw ArgumentError.value(
        groupId,
        'groupId',
        'is not a group you are in',
      );
    }
    final ts = _now;
    final next = ChatGroups.renew(group, memberId, ts);
    if (identical(next, group)) {
      throw ArgumentError.value(
        memberId,
        'memberId',
        'is not waiting to be invited',
      );
    }
    await store.saveGroup(next);
    await _invite(next, memberId);
    for (final other in next.memberIds) {
      if (other != myId && other != memberId) {
        _sendRenewal(next, other, memberId, ts);
      }
    }
    emit(group.id, GroupStateChanged(group.id), group: group.id);
  }

  /// Sends the other members the new invite to [memberId] of [group], dated
  /// [ts], through the relay, repeated like an invite is. A member who is not a
  /// contact gets nothing (D22).
  void _sendRenewal(ChatGroup group, String to, String memberId, int ts) {
    if (!isContact(to)) return;
    final body = ChatGroups.envelope(
      ChatGroups.encodeRenewal(group: group.id, member: memberId, ts: ts),
    );
    send(to, 'group.reinvite', body, null);
    _resends.add(
      _Resend(
        to: to,
        type: 'group.reinvite',
        body: body,
        until: _now + inviteWindow.inMilliseconds,
        nextAt: _now + groupResendEvery.inMilliseconds,
      ),
    );
  }

  /// Sends the invite to [memberId] and keeps it until it is answered or
  /// expires (see [tick]).
  Future<void> _invite(ChatGroup group, String memberId) async {
    final invite = ChatGroups.inviteFor(group, memberId);
    await store.queueInvite(
      PendingInvite(
        group: group.id,
        invitee: memberId,
        attempts: 1,
        sentAt: _now,
        expiry: invite.ts + inviteWindow.inMilliseconds,
      ),
    );
    _sendInvite(invite, memberId);
  }

  /// Sends [invite] to [memberId] through the relay, and as a direct frame when
  /// that member has a live session. A member who is not a contact gets
  /// nothing (D22).
  void _sendInvite(GroupInvite invite, String memberId) {
    if (!isContact(memberId)) return;
    send(
      memberId,
      'group.invite',
      ChatGroups.envelope(ChatGroups.encodeInvite(invite)),
      null,
    );
    sessionOf(memberId)?.sendGroupInvite(
      GroupInviteFrame(
        group: invite.group,
        name: invite.name,
        members: invite.members,
        ts: invite.ts,
      ),
    );
  }

  // Answers and leaving.

  /// Accepts the invite to [groupId], if it is still open (D11). Every other
  /// member is told. Returns what happened.
  Future<GroupJoinResult> accept(String groupId) async {
    _requireGroups();
    final group = await _group(groupId);
    final self = group.memberOf(myId);
    if (self == null ||
        (self.state != MemberState.invited &&
            self.state != MemberState.expired)) {
      return GroupJoinResult.notInvited;
    }
    if (ChatGroups.missingContacts(group, {
      for (final id in group.memberIds)
        if (isContact(id)) id,
    }).isNotEmpty) {
      return GroupJoinResult.missingContacts;
    }
    final ts = _now;
    final next = ChatGroups.accept(group, myId, ts);
    if (!identical(next, group)) {
      await store.saveGroup(next);
      emit(group.id, GroupStateChanged(group.id), group: group.id);
    }
    if (!ChatGroups.isActive(next)) return GroupJoinResult.expired;
    for (final member in next.memberIds) {
      if (member != myId) {
        await _answer(next, member, GroupStateKind.accept, ts, retry: true);
      }
    }
    return GroupJoinResult.joined;
  }

  /// Declines the invite to [groupId]. The decline is final (D23): a new
  /// invite is needed to join. Every other member is told.
  Future<bool> decline(String groupId) async {
    _requireGroups();
    final group = await _group(groupId);
    final self = group.memberOf(myId);
    if (self == null ||
        (self.state != MemberState.invited &&
            self.state != MemberState.expired)) {
      return false;
    }
    final ts = _now;
    final next = ChatGroups.decline(group, myId);
    await store.saveGroup(next);
    emit(group.id, GroupStateChanged(group.id), group: group.id);
    for (final member in next.memberIds) {
      if (member != myId) {
        await _answer(next, member, GroupStateKind.decline, ts, retry: true);
      }
    }
    return true;
  }

  /// Leaves [groupId]. The history stays on this device, read-only. Every other
  /// member is told, and the group goes on for the rest (D13).
  Future<bool> leave(String groupId) async {
    _requireGroups();
    final group = await _group(groupId);
    final self = group.memberOf(myId);
    if (self == null || self.state != MemberState.accepted) return false;
    final ts = _now;
    final next = ChatGroups.leave(group, myId);
    await store.saveGroup(next);
    emit(group.id, GroupStateChanged(group.id), group: group.id);
    for (final member in next.memberIds) {
      if (member != myId) {
        await _answer(next, member, GroupStateKind.leave, ts, retry: false);
      }
    }
    return true;
  }

  /// Sends an answer or a leave to [member]: through the relay (repeated for
  /// [retry]), and kept as a direct frame until that member's session takes
  /// it. A member who is not a contact gets nothing (D22).
  Future<void> _answer(
    ChatGroup group,
    String member,
    GroupStateKind kind,
    int ts, {
    required bool retry,
  }) async {
    if (!isContact(member)) return;
    final text = ChatGroups.encodeAnswer(kind, group: group.id, ts: ts);
    final type = 'group.${kind.name}';
    final body = ChatGroups.envelope(text);
    send(member, type, body, null);
    if (retry) {
      _resends.add(
        _Resend(
          to: member,
          type: type,
          body: body,
          until: _now + inviteWindow.inMilliseconds,
          nextAt: _now + groupResendEvery.inMilliseconds,
        ),
      );
    }
    await store.queueGroupState(
      group.id,
      member,
      GroupStateFrame(kind: kind, group: group.id, ts: ts),
      clock: clock,
    );
    await _flushMember(member);
  }

  // Messages.

  /// Sends a text to the group [groupId]. Each member gets its own copy: over
  /// its live session when there is one, otherwise through the relay (see
  /// [_sendRelayCopy]). A reply quotes only this device's own message (D25).
  Future<ChatMessage> sendText(
    String groupId,
    String text, {
    String? replyToId,
    bool forwarded = false,
  }) async {
    _requireGroups();
    final group = await _group(groupId);
    if (!ChatGroups.isActive(group)) {
      throw ArgumentError.value(
        groupId,
        'groupId',
        'is not a group you are in',
      );
    }
    final cleaned = ChatFrames.cleanText(text);
    if (cleaned.isEmpty || cleaned.runes.length > maxTextChars) {
      throw ArgumentError.value(
        text,
        'text',
        'must be 1 to $maxTextChars characters',
      );
    }
    final replyTo = replyToId == null ? null : await _quote(groupId, replyToId);
    final targets = _targets(group);
    final message = ChatMessage(
      id: newId(),
      contactId: group.id,
      groupId: group.id,
      authorId: myId,
      outgoing: true,
      ts: _now,
      text: cleaned,
      state: ChatState.sending,
      replyTo: replyTo,
      forwarded: forwarded,
      memberStates: {for (final member in targets) member: ChatState.sending},
    );
    final stored = await store.add(message);
    for (final member in targets) {
      final session = sessionOf(member);
      if (session != null) {
        await session.sendToGroup(stored);
      } else {
        _sendRelayCopy(member, stored);
      }
    }
    return stored;
  }

  /// The quote for a reply to [id] in [groupId]: only this device's own
  /// message, not deleted (D25).
  Future<ChatReply> _quote(String groupId, String id) async {
    final target = await store.find(groupId, id);
    if (target == null ||
        target.deletedForAll ||
        !ChatGroups.mayQuote(
          authorId: target.authorId ?? '',
          replierId: myId,
        )) {
      throw ArgumentError.value(
        id,
        'replyToId',
        'is not a message to reply to',
      );
    }
    return (id: target.id, text: ChatFrames.quoteText(target.text));
  }

  /// Whether [message] can go through the relay: the same texts as a one-to-one
  /// chat, which the relay can carry without a quote or a forwarded mark.
  static bool _relayable(ChatMessage message) =>
      message.outgoing &&
      !message.deletedForAll &&
      message.replyTo == null &&
      !message.forwarded;

  /// Sends the copy of [message] to [member] through the relay.
  void _sendRelayCopy(String member, ChatMessage message) {
    if (!isContact(member) || !_relayable(message)) return;
    send(
      member,
      'group.text',
      ChatGroups.envelope(
        ChatGroups.encodeRelayText(
          group: message.groupId!,
          id: message.id,
          ts: message.ts,
          text: message.text,
        ),
      ),
      null,
    );
  }

  /// Sets this device's reaction on message [id] in [groupId]; an empty [emoji]
  /// removes it. Sent to each member as a control (see [ChatSession]).
  Future<bool> react(String groupId, String id, String emoji) async {
    _requireGroups();
    final group = await _group(groupId);
    final String cleaned;
    try {
      cleaned = ChatFrames.cleanEmoji(emoji);
    } on ChatFrameException {
      throw ArgumentError.value(emoji, 'emoji', 'is not a reaction');
    }
    final message = await store.find(groupId, id);
    if (message == null || message.deletedForAll) return false;
    final changed = await store.changeMessage(
      groupId,
      id,
      (m) => m.deletedForAll ? null : m.withReaction(myId, cleaned),
    );
    if (!changed) return false;
    final ts = _now;
    for (final member in _targets(group)) {
      await store.queueControl(
        groupId,
        ReactFrame(id: id, emoji: cleaned, ts: ts, group: groupId),
        memberId: member,
        clock: clock,
      );
      await _flushMember(member);
    }
    return true;
  }

  /// Replaces the text of this device's own message [id] in [groupId], within
  /// the edit window. Sent to each member as a control.
  Future<bool> edit(String groupId, String id, String text) async {
    _requireGroups();
    final group = await _group(groupId);
    final cleaned = ChatFrames.cleanText(text);
    if (cleaned.isEmpty || cleaned.runes.length > maxTextChars) {
      throw ArgumentError.value(
        text,
        'text',
        'must be 1 to $maxTextChars characters',
      );
    }
    final message = await store.find(groupId, id);
    if (message == null ||
        !message.outgoing ||
        message.authorId != myId ||
        message.deletedForAll) {
      return false;
    }
    final ts = _now;
    if (!ChatFrames.withinWindow(message.ts, ts, editWindow)) return false;
    final changed = await store.changeMessage(
      groupId,
      id,
      (m) => m.deletedForAll ? null : m.copyWith(text: cleaned, editedAt: ts),
    );
    if (!changed) return false;
    for (final member in group.memberIds) {
      final session = sessionOf(member);
      session?.setTextOf(id, cleaned);
      session?.setQuotesOf(id, ChatFrames.quoteText(cleaned));
    }
    for (final member in _targets(group)) {
      await store.queueControl(
        groupId,
        EditFrame(id: id, ts: ts, text: cleaned, group: groupId),
        memberId: member,
        clock: clock,
      );
      await _flushMember(member);
    }
    return true;
  }

  /// Deletes this device's own message [id] in [groupId] for everyone, within
  /// the delete window. Sent to each member as a control.
  Future<bool> deleteForEveryone(String groupId, String id) async {
    _requireGroups();
    final group = await _group(groupId);
    final message = await store.find(groupId, id);
    if (message == null ||
        !message.outgoing ||
        message.authorId != myId ||
        message.deletedForAll) {
      return false;
    }
    final ts = _now;
    if (!ChatFrames.withinWindow(message.ts, ts, deleteWindow)) return false;
    final changed = await store.changeMessage(
      groupId,
      id,
      (m) => m.deletedForAll
          ? null
          : m.copyWith(text: '', deletedForAll: true, reactions: const {}),
    );
    if (!changed) return false;
    for (final member in group.memberIds) {
      final session = sessionOf(member);
      session?.setQuotesOf(id, '');
      session?.forget(id);
    }
    for (final member in _targets(group)) {
      await store.queueControl(
        groupId,
        DeleteFrame(id: id, ts: ts, group: groupId),
        memberId: member,
        clock: clock,
      );
      await _flushMember(member);
    }
    return true;
  }

  /// Sends read receipts for [ids] of [groupId] to each member with a live
  /// session. Only the author of a message gets its receipt (see
  /// [ChatSession.sendGroupReadReceipts]).
  Future<void> sendReadReceipts(String groupId, List<String> ids) async {
    if (!groupsEnabled || ids.isEmpty) return;
    final group = await store.group(groupId);
    if (group == null) return;
    for (final member in group.memberIds) {
      if (member != myId) {
        await sessionOf(member)?.sendGroupReadReceipts(groupId, ids);
      }
    }
  }

  /// Sends the group messages this device wrote and that [member] has not
  /// acknowledged yet, over the session that has just opened with it.
  Future<void> catchUp(String member, ChatSession session) async {
    if (!groupsEnabled) return;
    final since = _now - groupRelayWindow.inMilliseconds;
    for (final group in await store.groups()) {
      if (group.memberOf(member) == null) continue;
      for (final message in await store.messages(group.id)) {
        if (session.isEnded) return;
        if (!message.outgoing || message.ts < since) continue;
        final state = message.memberStates[member];
        if (state == ChatState.sending || state == ChatState.notSent) {
          await session.sendToGroup(message);
        }
      }
    }
  }

  // Receiving through the relay and the sessions.

  /// Handles a group envelope [type] from [from]. Envelopes of the wrong shape
  /// are dropped, as the rest are.
  Future<void> handle({
    required String from,
    required String type,
    required Map<String, dynamic> body,
  }) async {
    if (!groupsEnabled) return;
    final text = ChatGroups.textOf(body);
    if (text == null) return;
    try {
      switch (type) {
        case 'group.invite':
          if (!isContact(from)) return;
          await _receiveInvite(
            ChatGroups.decodeInvite(text, from: from, receiver: myId),
          );
        case 'group.text':
          await _receiveText(from, text);
        case 'group.accept':
          await _receiveAnswer(from, text, GroupStateKind.accept);
        case 'group.decline':
          await _receiveAnswer(from, text, GroupStateKind.decline);
        case 'group.leave':
          await _receiveAnswer(from, text, GroupStateKind.leave);
        case 'group.reinvite':
          await _receiveRenewal(from, text);
      }
    } on ChatFrameException {
      // A malformed or out-of-rule envelope is dropped; the sender resends
      // what still matters.
    }
  }

  /// A group invite that arrived on a direct session from [from].
  Future<void> receiveInviteFrame(GroupInviteFrame frame, String from) async {
    if (!groupsEnabled || !isContact(from)) return;
    try {
      await _receiveInvite(
        ChatGroups.validateInvite(
          group: frame.group,
          name: frame.name,
          members: frame.members,
          ts: frame.ts,
          inviter: from,
          receiver: myId,
        ),
      );
    } on ChatFrameException {
      // Dropped, as the relay copy of the same invite would be.
    }
  }

  Future<void> _receiveInvite(GroupInvite invite) async {
    final known = await store.group(invite.group);
    if (known == null) {
      final group = ChatGroups.fromInvite(invite, selfId: myId);
      await store.saveGroup(group);
      emit(group.id, GroupStateChanged(group.id), group: group.id);
      return;
    }
    // A group already held: a new invite counts only from a member of it (D23).
    if (known.memberOf(invite.inviter) == null) return;
    final next = ChatGroups.renew(known, myId, invite.ts);
    if (identical(next, known)) return;
    await store.saveGroup(next);
    emit(known.id, GroupStateChanged(known.id), group: known.id);
  }

  /// A new invite to a member, as another member of the group sends it on. It
  /// is taken only from a member of the group, and about a member of it.
  Future<void> _receiveRenewal(String from, String text) async {
    if (!isContact(from)) return;
    final renewal = ChatGroups.decodeRenewal(text);
    final group = await store.group(renewal.group);
    if (group == null || group.memberOf(from) == null) return;
    final next = ChatGroups.renew(group, renewal.member, renewal.ts);
    if (identical(next, group)) return;
    await store.saveGroup(next);
    emit(group.id, GroupStateChanged(group.id), group: group.id);
  }

  Future<void> _receiveText(String from, String text) async {
    if (!isContact(from)) return;
    final decoded = ChatGroups.decodeRelayText(text);
    final group = await store.group(decoded.group);
    if (group == null || !ChatGroups.isActive(group)) return;
    if (group.memberOf(from)?.state != MemberState.accepted) return;
    if (!await store.contains(group.id, decoded.id)) {
      final arrived = _now;
      final message = ChatMessage(
        id: decoded.id,
        contactId: group.id,
        groupId: group.id,
        authorId: from,
        outgoing: false,
        ts: ChatFrames.receivedTs(decoded.ts, arrived),
        text: decoded.text,
        state: ChatState.received,
        read: false,
        arrivedAt: arrived,
      );
      final stored = await store.add(message);
      emit(group.id, MessageReceived(stored), group: group.id);
    }
    send(from, _textAckType, {'id': decoded.id, 'group': group.id}, null);
  }

  /// A member stored a group text this device sent through the relay.
  Future<void> onTextAck(String from, String groupId, String id) async {
    if (!groupsEnabled || !ChatFrames.isId(id)) return;
    final group = await store.group(groupId);
    if (group == null || group.memberOf(from) == null) return;
    final message = await store.find(groupId, id);
    if (message == null || !message.outgoing || message.authorId != myId) {
      return;
    }
    final state = message.memberStates[from];
    if (state == ChatState.delivered || state == ChatState.read) return;
    await store.setState(groupId, id, ChatState.delivered, memberId: from);
    emit(groupId, MessageDelivered(id, group: groupId), group: groupId);
    await _flushMember(from);
  }

  Future<void> _receiveAnswer(
    String from,
    String text,
    GroupStateKind kind,
  ) async {
    if (!isContact(from)) return;
    final answer = ChatGroups.decodeAnswer(text, kind);
    final group = await store.group(answer.group);
    if (group == null || group.memberOf(from) == null) return;
    final next = ChatGroups.applyAnswer(group, from, kind, answer.ts);
    if (identical(next, group)) return;
    await store.saveGroup(next);
    emit(group.id, GroupStateChanged(group.id), group: group.id);
  }

  /// Times out invites nobody answered, sends the invites and answers that are
  /// due again, flushes the pending controls to members with a live session,
  /// and sends texts to groups through the relay while they are still
  /// unacknowledged.
  Future<void> tick() async {
    if (!groupsEnabled) return;
    final now = _now;
    for (final group in await store.groups()) {
      var current = group;
      for (final invite in await store.pendingInvites(group.id)) {
        final member = current.memberOf(invite.invitee);
        if (member == null || member.state != MemberState.invited) {
          await store.removeInvite(group.id, invite.invitee);
        } else if (now >= invite.expiry) {
          await store.removeInvite(group.id, invite.invitee);
          current = ChatGroups.expire(current, invite.invitee);
          await store.saveGroup(current);
          emit(group.id, GroupStateChanged(group.id), group: group.id);
        } else if (now - invite.sentAt >= groupResendEvery.inMilliseconds) {
          _sendInvite(
            ChatGroups.inviteFor(current, invite.invitee),
            invite.invitee,
          );
          await store.queueInvite(
            PendingInvite(
              group: group.id,
              invitee: invite.invitee,
              attempts: invite.attempts + 1,
              sentAt: now,
              expiry: invite.expiry,
            ),
          );
        }
      }
      for (final member in group.memberIds) {
        if (member != myId) await _flushMember(member);
      }
    }
    _resendAnswers(now);
    await _resendTexts(now);
  }

  void _resendAnswers(int now) {
    _resends.removeWhere((r) => now >= r.until);
    for (final resend in _resends) {
      if (now < resend.nextAt || !isContact(resend.to)) continue;
      send(resend.to, resend.type, resend.body, null);
      resend.nextAt = now + groupResendEvery.inMilliseconds;
    }
  }

  /// Sends again, through the relay, the group texts a member has not
  /// acknowledged. A member with a live session is skipped: its session sends
  /// the text. A text past its window marks the members that still wait as not
  /// sent.
  Future<void> _resendTexts(int now) async {
    final since = now - groupRelayWindow.inMilliseconds;
    var budget = maxGroupRelayPerTick;
    for (final group in await store.groups()) {
      if (!ChatGroups.isActive(group)) continue;
      for (final message in await store.messages(group.id)) {
        if (!message.outgoing || message.deletedForAll) continue;
        final waiting = [
          for (final entry in message.memberStates.entries)
            if (entry.value == ChatState.sending ||
                entry.value == ChatState.notSent)
              entry.key,
        ];
        if (waiting.isEmpty) continue;
        if (message.ts < since) {
          for (final member in waiting) {
            if (message.memberStates[member] == ChatState.sending) {
              await store.setState(
                group.id,
                message.id,
                ChatState.notSent,
                memberId: member,
              );
              emit(
                group.id,
                MessageNotSent(message.id, group: group.id),
                group: group.id,
              );
            }
          }
          continue;
        }
        if (!_relayable(message)) continue;
        for (final member in waiting) {
          if (budget <= 0) return;
          if (sessionOf(member)?.isReady ?? false) continue;
          final current = await store.findUndeleted(group.id, message.id);
          if (current == null || !_relayable(current)) break;
          _sendRelayCopy(member, current);
          budget--;
        }
      }
    }
  }

  /// Marks the group messages this device was sending when the app stopped as
  /// not sent, for the members that were still waiting.
  Future<void> recoverInterrupted() async {
    if (!groupsEnabled) return;
    for (final group in await store.groups()) {
      for (final message in await store.messages(group.id)) {
        if (!message.outgoing) continue;
        for (final entry in message.memberStates.entries) {
          if (entry.value != ChatState.sending) continue;
          await store.setState(
            group.id,
            message.id,
            ChatState.notSent,
            memberId: entry.key,
          );
          emit(
            group.id,
            MessageNotSent(message.id, group: group.id),
            group: group.id,
          );
        }
      }
    }
  }
}
