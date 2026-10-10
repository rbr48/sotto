import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_groups.dart';
import 'package:sotto/crypto/encoding.dart';

const _minute = 60 * 1000;

/// A fixed clock reading, in milliseconds.
const _now = 1700000000000;

/// A Sotto ID: 32 bytes of signing key, as base64url.
String _member(int n) => b64Encode(List<int>.filled(32, n));

/// A group id: 16 bytes, as base64url.
String _group(int n) => b64Encode(List<int>.filled(16, n));

/// The reason [action] throws, or null when it does not.
String? _refusedBy(void Function() action) {
  try {
    action();
    return null;
  } on ChatFrameException catch (e) {
    return e.reason;
  }
}

/// The reason an invite with these fields is dropped, or null when it is kept.
/// The defaults are a three-person invite from member 2 to member 1.
String? _dropped({
  String? group,
  String name = 'Trip',
  List<String>? members,
  int ts = _now,
  String? inviter,
  String? receiver,
  int nowMs = _now,
}) => _refusedBy(
  () => ChatGroups.validateInvite(
    group: group ?? _group(40),
    name: name,
    members: members ?? [_member(2), _member(1), _member(3)],
    ts: ts,
    inviter: inviter ?? _member(2),
    receiver: receiver ?? _member(1),
    nowMs: nowMs,
  ),
);

/// The reason a group made by [ChatGroups.create] is refused, or null.
String? _created({
  String name = 'Trip',
  required List<String> invitees,
  Set<String>? contacts,
  String? selfId,
  int ts = _now,
}) => _refusedBy(
  () => ChatGroups.create(
    selfId: selfId ?? _member(1),
    name: name,
    invitees: invitees,
    contacts: contacts ?? invitees.toSet(),
    ts: ts,
    random: Random(1),
  ),
);

void main() {
  group('membership', () {
    test('a group is made from two or three contacts, and the creator is '
        'accepted', () {
      final group = ChatGroups.create(
        selfId: _member(1),
        name: 'Trip',
        invitees: [_member(2), _member(3)],
        contacts: {_member(2), _member(3)},
        ts: _now,
        random: Random(1),
      );
      expect(ChatFrames.isId(group.id), isTrue);
      expect(group.name, 'Trip');
      expect(group.selfId, _member(1));
      expect(group.createdAt, _now);
      expect(group.memberIds, [_member(1), _member(2), _member(3)]);
      expect(group.memberOf(_member(1))!.state, MemberState.accepted);
      expect(group.memberOf(_member(2))!.state, MemberState.invited);
      expect(group.memberOf(_member(2))!.invitedAt, _now);
      expect(group.left, isFalse);
    });

    test('a group has three or four people in all, and no more', () {
      expect(_created(invitees: [_member(2)]), 'too-few');
      expect(_created(invitees: [_member(2), _member(3)]), isNull);
      expect(_created(invitees: [_member(2), _member(3), _member(4)]), isNull);
      expect(
        _created(invitees: [_member(2), _member(3), _member(4), _member(5)]),
        'too-many',
      );
      expect(
        _created(
          invitees: [
            _member(2),
            _member(3),
            _member(4),
            _member(5),
            _member(6),
          ],
        ),
        'too-many',
      );
    });

    test('an invitee must be a contact, and not repeated, this device, or not '
        'a Sotto ID', () {
      expect(
        _created(invitees: [_member(2), _member(3)], contacts: {_member(2)}),
        'not-contact',
      );
      expect(_created(invitees: [_member(2), _member(2)]), 'malformed');
      expect(_created(invitees: [_member(2), _member(1)]), 'malformed');
      expect(_created(invitees: [_member(2), 'nope']), 'malformed');
      expect(_created(invitees: [_member(2), _member(3)], ts: 0), 'malformed');
      expect(
        _created(invitees: [_member(2), _member(3)], selfId: 'nope'),
        'malformed',
      );
    });

    test('a group id is 16 random bytes, unpadded base64url, and differs per '
        'group', () {
      final first = ChatGroups.create(
        selfId: _member(1),
        name: 'Trip',
        invitees: [_member(2), _member(3)],
        contacts: {_member(2), _member(3)},
        ts: _now,
        random: Random(1),
      ).id;
      final second = ChatGroups.create(
        selfId: _member(1),
        name: 'Trip',
        invitees: [_member(2), _member(3)],
        contacts: {_member(2), _member(3)},
        ts: _now,
        random: Random(2),
      ).id;
      expect(first, hasLength(22));
      expect(ChatFrames.isId(first), isTrue);
      expect(second, isNot(first));
    });

    test('a member id is a 32-byte key, and nothing else is', () {
      expect(ChatGroups.isMemberId(_member(1)), isTrue);
      expect(ChatGroups.isMemberId(_group(1)), isFalse);
      expect(ChatGroups.isMemberId('${_member(1)}='), isFalse);
      expect(ChatGroups.isMemberId('not an id'), isFalse);
      expect(ChatGroups.isMemberId(42), isFalse);
      expect(ChatGroups.isMemberId(null), isFalse);
    });
  });

  group('group names', () {
    test('a name loses its control characters, line breaks and direction '
        'overrides, and its ends are trimmed', () {
      expect(ChatGroups.cleanName('  Family  '), 'Family');
      expect(ChatGroups.cleanName('a\u0007b'), 'ab');
      expect(ChatGroups.cleanName('line\none\tline'), 'lineoneline');
      expect(ChatGroups.cleanName('x\u{202E}y\u{2066}z'), 'xyz');
      expect(ChatGroups.cleanName('\u0000\u007F'), '');
    });

    test('a name is 1 to 64 characters after cleaning', () {
      expect(_dropped(name: ''), 'malformed');
      expect(_dropped(name: ' \u0007 '), 'malformed');
      expect(_dropped(name: 'a'), isNull);
      expect(_dropped(name: 'a' * 64), isNull);
      expect(_dropped(name: 'a' * 65), 'too-long');
      // Characters, not bytes: 64 emoji are a name, 65 are too long.
      expect(_dropped(name: '\u{1F389}' * 64), isNull);
      expect(_dropped(name: '\u{1F389}' * 65), 'too-long');
      // Control characters go before the count.
      expect(_dropped(name: 'a\u0001' * 64), isNull);
    });

    test(
      'creation applies the same name rules, and keeps the cleaned name',
      () {
        expect(
          _created(name: '', invitees: [_member(2), _member(3)]),
          'malformed',
        );
        expect(
          _created(name: 'b' * 65, invitees: [_member(2), _member(3)]),
          'too-long',
        );
        final group = ChatGroups.create(
          selfId: _member(1),
          name: ' Trip\n',
          invitees: [_member(2), _member(3)],
          contacts: {_member(2), _member(3)},
          ts: _now,
          random: Random(1),
        );
        expect(group.name, 'Trip');
      },
    );
  });

  group('invite validation (D24)', () {
    test('an invite with two others, three people in all, is kept', () {
      expect(_dropped(), isNull);
    });

    test('an invite with three others, four people in all, is kept', () {
      expect(
        _dropped(members: [_member(2), _member(1), _member(3), _member(4)]),
        isNull,
      );
    });

    test('an invite with four others, five people in all, is dropped', () {
      expect(
        _dropped(
          members: [_member(2), _member(1), _member(3), _member(4), _member(5)],
        ),
        'too-many',
      );
    });

    test('an invite with five others, six people in all, is dropped', () {
      expect(
        _dropped(
          members: [
            _member(2),
            _member(1),
            _member(3),
            _member(4),
            _member(5),
            _member(6),
          ],
        ),
        'too-many',
      );
    });

    test('an invite with one other, two people in all, is dropped', () {
      expect(_dropped(members: [_member(2), _member(1)]), 'too-few');
    });

    test('an invite must name the inviter and the receiver', () {
      expect(
        _dropped(members: [_member(1), _member(3), _member(4)]),
        'malformed',
      );
      expect(
        _dropped(members: [_member(2), _member(3), _member(4)]),
        'malformed',
      );
      expect(
        _dropped(
          inviter: _member(1),
          receiver: _member(1),
          members: [_member(1), _member(3), _member(4)],
        ),
        'malformed',
      );
    });

    test('a repeated member, a member that is not a Sotto ID, a malformed '
        'group id and a bad ts are dropped', () {
      expect(
        _dropped(members: [_member(2), _member(1), _member(3), _member(3)]),
        'malformed',
      );
      expect(_dropped(members: [_member(2), _member(1), 'nope']), 'malformed');
      expect(_dropped(group: 'abc'), 'malformed');
      expect(_dropped(ts: 0), 'malformed');
      expect(_dropped(ts: -1), 'malformed');
    });

    test('an invite dated more than the clock skew ahead is dropped', () {
      expect(_dropped(ts: _now + 5 * _minute), isNull);
      expect(_dropped(ts: _now + 5 * _minute + 1), 'malformed');
    });
  });

  group('invite body', () {
    final good = {
      't': 'group.invite',
      'group': _group(40),
      'name': 'Trip',
      'members': [_member(2), _member(1), _member(3)],
      'ts': _now,
    };

    String? refused(String text) => _refusedBy(
      () => ChatGroups.decodeInvite(
        text,
        from: _member(2),
        receiver: _member(1),
        nowMs: _now,
      ),
    );

    test('an invite round-trips and is padded to a bucket', () {
      final invite = GroupInvite(
        group: _group(40),
        name: 'Trip',
        members: [_member(2), _member(1), _member(3)],
        ts: _now,
        inviter: _member(2),
      );
      final text = ChatGroups.encodeInvite(invite);
      expect(utf8.encode(text).length % padBucketBytes, 0);
      final read = ChatGroups.decodeInvite(
        text,
        from: _member(2),
        receiver: _member(1),
        nowMs: _now,
      );
      expect(read.group, _group(40));
      expect(read.name, 'Trip');
      expect(read.members, [_member(2), _member(1), _member(3)]);
      expect(read.ts, _now);
      expect(read.inviter, _member(2));
    });

    test('an invite body is refused when it is not an invite, is malformed or '
        'is too large', () {
      expect(refused(jsonEncode(good)), isNull);
      expect(refused(jsonEncode({...good, 't': 'group.text'})), 'malformed');
      expect(refused('not json'), 'malformed');
      expect(refused('[]'), 'malformed');
      expect(refused(jsonEncode({...good, 'members': 'x'})), 'malformed');
      expect(
        refused(
          jsonEncode({
            ...good,
            'members': [_member(2), 7, _member(3)],
          }),
        ),
        'malformed',
      );
      expect(refused(jsonEncode({...good, 'name': null})), 'malformed');
      expect(refused(jsonEncode({...good, 'ts': '5'})), 'malformed');
      expect(refused(jsonEncode({...good, 'group': null})), 'malformed');
      expect(refused(jsonEncode({...good, 'pad': ' ' * 16384})), 'too-large');
    });

    test('an invite body that omits the receiver is dropped', () {
      expect(
        refused(
          jsonEncode({
            ...good,
            'members': [_member(2), _member(3), _member(4)],
          }),
        ),
        'malformed',
      );
    });

    test('decoding ignores the pad field of an invite', () {
      expect(refused(jsonEncode({...good, 'pad': 3})), isNull);
      expect(refused(jsonEncode({...good, 'pad': ' ' * 900})), isNull);
    });
  });

  group('the invite a device holds', () {
    test('the inviter is accepted, and every other member is invited at the '
        'invite time', () {
      final invite = GroupInvite(
        group: _group(40),
        name: 'Trip',
        members: [_member(2), _member(1), _member(3)],
        ts: _now,
        inviter: _member(2),
      );
      final group = ChatGroups.fromInvite(invite, selfId: _member(1));
      expect(group.id, _group(40));
      expect(group.name, 'Trip');
      expect(group.createdAt, _now);
      expect(group.selfId, _member(1));
      expect(group.memberIds, invite.members);
      expect(group.memberOf(_member(2))!.state, MemberState.accepted);
      expect(group.memberOf(_member(1))!.state, MemberState.invited);
      expect(group.memberOf(_member(3))!.state, MemberState.invited);
      expect(group.memberOf(_member(3))!.invitedAt, _now);
    });

    test('fromInvite refuses an invite that does not name this device', () {
      final invite = GroupInvite(
        group: _group(40),
        name: 'Trip',
        members: [_member(2), _member(1), _member(3)],
        ts: _now,
        inviter: _member(2),
      );
      expect(
        _refusedBy(() => ChatGroups.fromInvite(invite, selfId: _member(9))),
        'malformed',
      );
    });

    test('an invite from creation to the receiver keeps the group', () {
      final made = ChatGroups.create(
        selfId: _member(1),
        name: 'Trip',
        invitees: [_member(2), _member(3)],
        contacts: {_member(2), _member(3)},
        ts: _now,
        random: Random(3),
      );
      final invite = ChatGroups.inviteFor(made, ts: _now + 1000);
      expect(invite.inviter, _member(1));
      expect(invite.name, 'Trip');
      final text = ChatGroups.encodeInvite(invite);
      final read = ChatGroups.decodeInvite(
        text,
        from: _member(1),
        receiver: _member(2),
        nowMs: _now,
      );
      final held = ChatGroups.fromInvite(read, selfId: _member(2));
      expect(held.id, made.id);
      expect(held.name, made.name);
      expect(held.memberIds, made.memberIds);
      expect(held.createdAt, _now + 1000);
      expect(held.memberOf(_member(1))!.state, MemberState.accepted);
    });
  });

  group('state transitions (D11, D13, D22, D23)', () {
    /// The creator's table: member 1 is this device, members 2 and 3 are
    /// invited at [_now].
    ChatGroup threeWay() => ChatGroups.create(
      selfId: _member(1),
      name: 'Trip',
      invitees: [_member(2), _member(3)],
      contacts: {_member(2), _member(3)},
      ts: _now,
      random: Random(1),
    );

    MemberState stateOf(ChatGroup group, String memberId) =>
        group.memberOf(memberId)!.state;

    test('an accept in the window is honoured, from the invite to the window '
        'end plus the clock skew', () {
      final group = threeWay();
      final end = _now + 15 * _minute + 5 * _minute;
      expect(
        stateOf(ChatGroups.accept(group, _member(2), _now), _member(2)),
        MemberState.accepted,
      );
      expect(
        stateOf(ChatGroups.accept(group, _member(2), end), _member(2)),
        MemberState.accepted,
      );
    });

    test('an accept just after the window end plus the clock skew expires the '
        'member', () {
      final group = threeWay();
      final late = _now + 20 * _minute + 1;
      expect(
        stateOf(ChatGroups.accept(group, _member(2), late), _member(2)),
        MemberState.expired,
      );
    });

    test('an accept a little before the invite is honoured for clock skew, and '
        'one further before expires the member', () {
      final group = threeWay();
      expect(
        stateOf(
          ChatGroups.accept(group, _member(2), _now - 5 * _minute),
          _member(2),
        ),
        MemberState.accepted,
      );
      expect(
        stateOf(
          ChatGroups.accept(group, _member(2), _now - 5 * _minute - 1),
          _member(2),
        ),
        MemberState.expired,
      );
    });

    test('an expired member joins on an accept in the window, so a local '
        'expiry decides nothing', () {
      final group = threeWay();
      final expired = ChatGroups.expire(group, _member(2));
      expect(stateOf(expired, _member(2)), MemberState.expired);
      expect(
        stateOf(
          ChatGroups.accept(expired, _member(2), _now + 3 * _minute),
          _member(2),
        ),
        MemberState.accepted,
      );
    });

    test('an expired member stays expired on a late accept', () {
      final late = ChatGroups.accept(
        threeWay(),
        _member(2),
        _now + 21 * _minute,
      );
      expect(stateOf(late, _member(2)), MemberState.expired);
      expect(
        stateOf(
          ChatGroups.accept(late, _member(2), _now + 30 * _minute),
          _member(2),
        ),
        MemberState.expired,
      );
    });

    test('expire marks only an invited member', () {
      final group = threeWay();
      expect(
        stateOf(ChatGroups.expire(group, _member(2)), _member(2)),
        MemberState.expired,
      );
      final accepted = ChatGroups.accept(group, _member(2), _now);
      expect(
        stateOf(ChatGroups.expire(accepted, _member(2)), _member(2)),
        MemberState.accepted,
      );
    });

    test('a decline is final: a later accept does not join, even in the '
        'window', () {
      final declined = ChatGroups.decline(threeWay(), _member(2));
      expect(stateOf(declined, _member(2)), MemberState.declined);
      final tried = ChatGroups.accept(declined, _member(2), _now + _minute);
      expect(stateOf(tried, _member(2)), MemberState.declined);
    });

    test('a declined member joins only through a new invite (D23)', () {
      final declined = ChatGroups.decline(threeWay(), _member(2));
      final invitedAgain = ChatGroups.reinvite(
        declined,
        _member(2),
        _now + 60 * _minute,
      );
      expect(stateOf(invitedAgain, _member(2)), MemberState.invited);
      expect(invitedAgain.memberOf(_member(2))!.invitedAt, _now + 60 * _minute);
      // The answer is judged against the new invite, not the old one.
      expect(
        stateOf(
          ChatGroups.accept(invitedAgain, _member(2), _now + _minute),
          _member(2),
        ),
        MemberState.expired,
      );
      expect(
        stateOf(
          ChatGroups.accept(invitedAgain, _member(2), _now + 61 * _minute),
          _member(2),
        ),
        MemberState.accepted,
      );
    });

    test('a decline or a new invite does not change an accepted member', () {
      final accepted = ChatGroups.accept(threeWay(), _member(2), _now);
      expect(
        stateOf(ChatGroups.decline(accepted, _member(2)), _member(2)),
        MemberState.accepted,
      );
      expect(
        stateOf(
          ChatGroups.reinvite(accepted, _member(2), _now + _minute),
          _member(2),
        ),
        MemberState.accepted,
      );
    });

    test('an answer from someone who is not a member changes nothing', () {
      final group = threeWay();
      expect(
        ChatGroups.accept(group, _member(9), _now).memberIds,
        group.memberIds,
      );
      expect(ChatGroups.decline(group, _member(9)).memberIds, group.memberIds);
    });

    test('a member who has accepted leaves, and an invited one cannot', () {
      final group = threeWay();
      expect(
        stateOf(ChatGroups.leave(group, _member(2)), _member(2)),
        MemberState.invited,
      );
      final accepted = ChatGroups.accept(group, _member(2), _now);
      final left = ChatGroups.leave(accepted, _member(2));
      expect(stateOf(left, _member(2)), MemberState.left);
      expect(left.memberIds, group.memberIds);
    });

    test('this device leaves its own group, and is then no longer active', () {
      final group = threeWay();
      expect(ChatGroups.isActive(group), isTrue);
      final left = ChatGroups.leave(group, _member(1));
      expect(left.left, isTrue);
      expect(ChatGroups.isActive(left), isFalse);
      expect(ChatGroups.sendTargets(left, {_member(2), _member(3)}), isEmpty);
    });

    test('a group of two stays active after a member leaves (D13)', () {
      var group = threeWay();
      group = ChatGroups.accept(group, _member(2), _now);
      group = ChatGroups.accept(group, _member(3), _now);
      group = ChatGroups.leave(group, _member(3));
      expect(ChatGroups.isActive(group), isTrue);
      expect(group.left, isFalse);
      expect(ChatGroups.sendTargets(group, {_member(2), _member(3)}), [
        _member(2),
      ]);
    });

    test('a message goes only to accepted members who are contacts', () {
      final group = threeWay();
      expect(
        ChatGroups.sendTargets(group, {_member(2), _member(3)}),
        isEmpty,
        reason: 'nobody has accepted',
      );
      final accepted = ChatGroups.accept(group, _member(2), _now);
      expect(ChatGroups.sendTargets(accepted, {_member(2), _member(3)}), [
        _member(2),
      ]);
    });

    test('a device that has declined its own invite sends nothing', () {
      final invite = GroupInvite(
        group: _group(40),
        name: 'Trip',
        members: [_member(2), _member(1), _member(3)],
        ts: _now,
        inviter: _member(2),
      );
      final held = ChatGroups.fromInvite(invite, selfId: _member(1));
      final declined = ChatGroups.decline(held, _member(1));
      expect(ChatGroups.isActive(declined), isFalse);
      expect(
        ChatGroups.sendTargets(declined, {_member(2), _member(3)}),
        isEmpty,
      );
    });

    test('a contact removed mid-group keeps its place, and gets nothing '
        'further (D22)', () {
      var group = threeWay();
      group = ChatGroups.accept(group, _member(2), _now);
      group = ChatGroups.accept(group, _member(3), _now);
      final contacts = {_member(2)};
      expect(ChatGroups.sendTargets(group, contacts), [_member(2)]);
      expect(ChatGroups.missingContacts(group, contacts), [_member(3)]);
      // Membership and states are as they were.
      expect(group.memberIds, [_member(1), _member(2), _member(3)]);
      expect(stateOf(group, _member(3)), MemberState.accepted);
      expect(ChatGroups.isActive(group), isTrue);
    });

    test('a joiner needs every other member as a contact (D3)', () {
      final invite = GroupInvite(
        group: _group(40),
        name: 'Trip',
        members: [_member(2), _member(1), _member(3)],
        ts: _now,
        inviter: _member(2),
      );
      final held = ChatGroups.fromInvite(invite, selfId: _member(1));
      expect(ChatGroups.missingContacts(held, {_member(2)}), [_member(3)]);
      expect(
        ChatGroups.missingContacts(held, {_member(2), _member(3)}),
        isEmpty,
      );
    });

    test(
      'a reply in a group may quote only the replier\'s own message (D25)',
      () {
        expect(
          ChatGroups.mayQuote(authorId: _member(1), replierId: _member(1)),
          isTrue,
        );
        expect(
          ChatGroups.mayQuote(authorId: _member(2), replierId: _member(1)),
          isFalse,
        );
      },
    );
  });
}
