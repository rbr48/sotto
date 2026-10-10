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
}
