/// Where a member stands in a group, as one device records it.
enum MemberState {
  /// Invited, and no answer yet.
  invited,

  /// Accepted. An accepted member receives the group's messages.
  accepted,

  /// Declined. Final until a new invite (D23).
  declined,

  /// Left after accepting. The history stays on the devices that have it.
  left,

  /// No answer in time, or a late one. A later answer in the window still counts.
  expired,
}

/// A member of a group, and the invite its state answers.
final class GroupMember {
  const GroupMember({
    required this.id,
    required this.state,
    required this.invitedAt,
  });

  /// The member's Sotto ID: its signing key, unpadded base64url.
  final String id;

  final MemberState state;

  /// The ts of the invite this state answers. An answer is judged against it.
  final int invitedAt;

  GroupMember withState(MemberState next) =>
      GroupMember(id: id, state: next, invitedAt: invitedAt);
}

/// A group as one device knows it. Each device keeps its own table of members
/// and their states, and no device sees another's table.
final class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.name,
    required this.selfId,
    required this.createdAt,
    required this.members,
  });

  /// 16 random bytes, unpadded base64url.
  final String id;

  /// The name after cleaning: 1 to 64 characters. Set at creation and never
  /// changed (D12).
  final String name;

  /// This device's member id. It is one of the [members].
  final String selfId;

  /// When the group was created: the ts of its first invite.
  final int createdAt;

  /// Every member, this device included, in the order they were invited.
  final List<GroupMember> members;

  /// The ids of the members, this device included.
  List<String> get memberIds => [for (final member in members) member.id];

  /// Whether this device has left the group.
  bool get left => memberOf(selfId)?.state == MemberState.left;

  /// The entry for [memberId], or null when it is not a member.
  GroupMember? memberOf(String memberId) {
    for (final member in members) {
      if (member.id == memberId) return member;
    }
    return null;
  }

  /// This group with [next] in place of the member of the same id.
  ChatGroup withMember(GroupMember next) => ChatGroup(
    id: id,
    name: name,
    selfId: selfId,
    createdAt: createdAt,
    members: [
      for (final member in members) member.id == next.id ? next : member,
    ],
  );
}
