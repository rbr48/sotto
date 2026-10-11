import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_group_manager.dart';
import 'package:sotto/chat/chat_groups.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity_store.dart';

import 'support/fake_network.dart';

/// A Sotto ID: 32 bytes of signing key, as base64url.
String _member(int n) => b64Encode(List<int>.filled(32, n));

/// A group id or message id: 16 bytes, as base64url.
String _id(int n) => b64Encode(List<int>.filled(16, n));

final _alice = _member(1);
final _bob = _member(2);
final _carol = _member(3);

Future<void> _settle() async {
  for (var i = 0; i < 300; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _minute = Duration(minutes: 1);

void main() {
  late FakeNetwork net;
  late DateTime now;
  final managers = <ChatManager>[];

  setUp(() {
    net = FakeNetwork();
    now = DateTime.utc(2026, 10, 9, 12);
    managers.clear();
  });

  tearDown(() async {
    for (final manager in managers) {
      await manager.dispose();
    }
  });

  /// One device of the person [myId], that takes the contacts [contacts].
  ChatManager device(
    String myId, {
    required Set<String> contacts,
    bool groupsEnabled = true,
    ChatStore? store,
  }) {
    final manager = ChatManager(
      myId: myId,
      store: store ?? ChatStore(MemorySecretStore()),
      isContact: contacts.contains,
      send: (to, type, body, callId) =>
          net.deliver(myId, to, type, body, callId),
      iceServers: () async => const [],
      hideIp: () => false,
      createRtc: ({required iceServers, required relayOnly}) async {
        final rtc = FakeRtc(net.registry)..relayOnly = relayOnly;
        (net.rtcs[myId] ??= []).add(rtc);
        return rtc;
      },
      clock: () => now,
      connectTimeout: const Duration(milliseconds: 200),
      offerReadyWait: Duration.zero,
      groupsEnabled: groupsEnabled,
    );
    managers.add(manager);
    (net.managers[myId] ??= []).add(manager);
    return manager;
  }

  /// The group [id] as [manager] holds it.
  Future<ChatGroup> held(ChatManager manager, String id) async =>
      (await manager.store.group(id))!;

  /// The number of envelopes of [type] sent to [to].
  int sentTo(String to, String type) =>
      net.sent.where((s) => s.to == to && s.type == type).length;

  /// Alice creates a group with Bob and Carol, and both accept it.
  Future<ChatGroup> threeMade({
    required ChatManager alice,
    required ChatManager bob,
    required ChatManager carol,
  }) async {
    final group = await alice.groups.create(
      name: 'Trip',
      invitees: [_bob, _carol],
    );
    await _settle();
    expect(await bob.groups.accept(group.id), GroupJoinResult.joined);
    expect(await carol.groups.accept(group.id), GroupJoinResult.joined);
    await _settle();
    return group;
  }

  group('making and answering an invite', () {
    test('a group is made among contacts, and each invitee gets the invite '
        'through the relay', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});

      final group = await alice.groups.create(
        name: 'Trip',
        invitees: [_bob, _carol],
      );
      await _settle();

      expect(
        net.sent
            .where((s) => s.type == 'group.invite')
            .map((s) => s.to)
            .toSet(),
        {_bob, _carol},
      );
      final atBob = await held(bob, group.id);
      expect(atBob.name, 'Trip');
      expect(atBob.memberOf(_alice)!.state, MemberState.accepted);
      expect(atBob.memberOf(_bob)!.state, MemberState.invited);
      expect(
        (await held(carol, group.id)).memberOf(_carol)!.state,
        MemberState.invited,
      );
    });

    test('a group needs two or three other contacts (D24)', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      await expectLater(
        alice.groups.create(name: 'Solo', invitees: [_bob]),
        throwsArgumentError,
      );
      await expectLater(
        alice.groups.create(name: 'Stranger', invitees: [_bob, _member(9)]),
        throwsArgumentError,
      );
    });

    test('an accept joins the group for the others too; a decline is final, '
        'and a new invite is needed to join again', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await alice.groups.create(
        name: 'Trip',
        invitees: [_bob, _carol],
      );
      await _settle();

      expect(await bob.groups.accept(group.id), GroupJoinResult.joined);
      await _settle();
      expect(
        (await held(alice, group.id)).memberOf(_bob)!.state,
        MemberState.accepted,
      );

      expect(await carol.groups.decline(group.id), isTrue);
      await _settle();
      expect(
        (await held(alice, group.id)).memberOf(_carol)!.state,
        MemberState.declined,
      );
      expect(
        await carol.groups.accept(group.id),
        GroupJoinResult.notInvited,
        reason: 'a decline is final (D23)',
      );

      now = now.add(_minute);
      await alice.groups.invite(group.id, _carol);
      await _settle();
      expect(await carol.groups.accept(group.id), GroupJoinResult.joined);
      await _settle();

      expect(
        (await held(alice, group.id)).memberOf(_carol)!.state,
        MemberState.accepted,
      );
      expect(
        (await held(bob, group.id)).memberOf(_carol)!.state,
        MemberState.accepted,
        reason: 'the other members learn the re-join from its accept',
      );
    });

    test('a late accept counts inside the window and not after it, '
        'measured by its own ts (D11)', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      device(_carol, contacts: {_alice, _bob});
      final first = await alice.groups.create(
        name: 'Trip',
        invitees: [_bob, _carol],
      );
      final second = await alice.groups.create(
        name: 'Trip two',
        invitees: [_bob, _carol],
      );
      await _settle();

      // The window is 15 minutes from the invite, plus the 5 minute clock
      // skew: the last moment an accept is in it.
      now = now.add(const Duration(minutes: 20));
      expect(await bob.groups.accept(first.id), GroupJoinResult.joined);
      await _settle();
      expect(
        (await held(alice, first.id)).memberOf(_bob)!.state,
        MemberState.accepted,
      );

      now = now.add(const Duration(milliseconds: 1));
      expect(await bob.groups.accept(second.id), GroupJoinResult.expired);
      await _settle();
      expect(
        (await held(bob, second.id)).memberOf(_bob)!.state,
        MemberState.expired,
      );
    });

    test('an invite with one other, or with five others, is dropped', () async {
      final bob = device(_bob, contacts: {_alice, _carol});
      device(_alice, contacts: {_bob});
      final idGroup = _id(40);

      GroupInvite invite(List<String> members) => GroupInvite(
        group: idGroup,
        name: 'Trip',
        members: members,
        ts: now.millisecondsSinceEpoch,
        inviter: _alice,
      );

      final one = ChatGroups.encodeInvite(invite([_alice, _bob]));
      bob.handle(
        from: _alice,
        type: 'group.invite',
        body: ChatGroups.envelope(one),
        callId: null,
      );
      final five = ChatGroups.encodeInvite(
        invite([_alice, _bob, _carol, _member(4), _member(5), _member(6)]),
      );
      bob.handle(
        from: _alice,
        type: 'group.invite',
        body: ChatGroups.envelope(five),
        callId: null,
      );
      await _settle();

      expect(await bob.store.group(idGroup), isNull);
    });
  });

  group('the group feature and groups off', () {
    test('with groups off, group envelopes are ignored, and nothing is sent '
        'to a group', () async {
      final alice = device(
        _alice,
        contacts: {_bob, _carol},
        groupsEnabled: false,
      );
      final bob = device(
        _bob,
        contacts: {_alice, _carol},
        groupsEnabled: false,
      );

      await expectLater(
        alice.groups.create(name: 'Trip', invitees: [_bob, _carol]),
        throwsStateError,
      );
      final group = ChatGroups.create(
        selfId: _alice,
        name: 'Trip',
        invitees: [_bob, _carol],
        contacts: {_bob, _carol},
        ts: now.millisecondsSinceEpoch,
      );
      final invite = ChatGroups.encodeInvite(ChatGroups.inviteFor(group, _bob));
      bob.handle(
        from: _alice,
        type: 'group.invite',
        body: ChatGroups.envelope(invite),
        callId: null,
      );
      await _settle();

      expect(await bob.store.group(group.id), isNull);
      expect(net.sent, isEmpty);
    });

    test('a group text from a member is ignored with groups off', () async {
      final bob = device(_bob, contacts: {_alice}, groupsEnabled: false);
      device(_alice, contacts: {_bob});
      final text = ChatGroups.encodeRelayText(
        group: _id(40),
        id: _id(7),
        ts: now.millisecondsSinceEpoch,
        text: 'Hi',
      );
      bob.handle(
        from: _alice,
        type: 'group.text',
        body: ChatGroups.envelope(text),
        callId: null,
      );
      await _settle();

      expect(await bob.store.group(_id(40)), isNull);
      expect(await bob.store.contains(_id(40), _id(7)), isFalse);
    });
  });

  group('a contact who is not a contact any more (D22)', () {
    test(
      'keeps its membership, gets nothing further, and no message is sent',
      () async {
        final aliceContacts = {_bob, _carol};
        final alice = device(_alice, contacts: aliceContacts);
        final bob = device(_bob, contacts: {_alice, _carol});
        final carol = device(_carol, contacts: {_alice, _bob});
        final group = await threeMade(alice: alice, bob: bob, carol: carol);

        aliceContacts.remove(_carol);
        final sentBefore = net.sent.length;
        final message = await alice.groups.sendText(group.id, 'Still here?');
        await _settle();

        expect(net.sent.skip(sentBefore).where((s) => s.to == _carol), isEmpty);
        expect(sentTo(_bob, 'group.text'), 1);
        final kept = await held(alice, group.id);
        expect(kept.memberOf(_carol)!.state, MemberState.accepted);
        expect(message.memberStates.keys.toList(), [_bob]);
        expect(ChatGroups.missingContacts(kept, aliceContacts), [_carol]);
      },
    );
  });

  group('messages in a group', () {
    test('a text goes to a member through the relay, and to the others as '
        'they receive it', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);

      final message = await alice.groups.sendText(group.id, 'Hello all');
      await _settle();

      expect(sentTo(_bob, 'group.text'), 1);
      expect(sentTo(_carol, 'group.text'), 1);
      final atBob = await bob.store.find(group.id, message.id);
      expect(atBob!.authorId, _alice);
      expect(atBob.text, 'Hello all');
      expect(atBob.outgoing, isFalse);
      final sent = await alice.store.find(group.id, message.id);
      expect(sent!.memberStates, {
        _bob: ChatState.delivered,
        _carol: ChatState.delivered,
      });
    });

    test('a member with a live session gets the text over it, and the relay '
        'carries it to the others', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);

      await alice.sendText(_bob, 'open the chat');
      await _settle();
      final sentBefore = net.sent.length;
      await alice.groups.sendText(group.id, 'Direct to Bob');
      await _settle();

      expect(
        net.sent
            .skip(sentBefore)
            .where((s) => s.to == _bob && s.type == 'group.text'),
        isEmpty,
      );
      expect(sentTo(_carol, 'group.text'), greaterThan(0));
      final frames = net.rtcs[_alice]!
          .expand((rtc) => rtc.sentFrames)
          .map(ChatFrames.decode)
          .whereType<GroupMsgFrame>()
          .map((frame) => frame.text);
      expect(frames, contains('Direct to Bob'));
    });

    test('a reply, which the relay does not carry, goes to a member when its '
        'session opens', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);
      final first = await alice.groups.sendText(group.id, 'First');
      await _settle();

      final reply = await alice.groups.sendText(
        group.id,
        'A reply',
        replyToId: first.id,
      );
      await _settle();
      expect(await bob.store.find(group.id, reply.id), isNull);

      await alice.sendText(_bob, 'open the chat');
      await _settle();

      final heard = await bob.store.find(group.id, reply.id);
      expect(heard, isNotNull);
      expect(heard!.replyTo?.id, first.id);
      expect(
        (await alice.store.find(group.id, reply.id))!.memberStates[_bob],
        ChatState.delivered,
      );
    });

    test('a group text still being sent when the app stopped is not sent for '
        'the members that were waiting', () async {
      final aliceStore = ChatStore(MemorySecretStore());
      final alice = device(_alice, contacts: {_bob, _carol}, store: aliceStore);
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);
      net.managers.remove(_carol);
      final message = await alice.groups.sendText(group.id, 'Interrupted');
      await _settle();
      expect(
        (await aliceStore.find(group.id, message.id))!.memberStates[_carol],
        ChatState.sending,
      );

      await alice.dispose();
      managers.remove(alice);
      net.managers[_alice]!.remove(alice);
      final restarted = device(
        _alice,
        contacts: {_bob, _carol},
        store: aliceStore,
      );
      await restarted.recoverInterrupted();

      final after = await aliceStore.find(group.id, message.id);
      expect(after!.memberStates[_carol], ChatState.notSent);
      expect(after.memberStates[_bob], ChatState.delivered);
    });

    test('a reply quotes only this device\'s own message (D25)', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);

      final fromBob = await bob.groups.sendText(group.id, 'From Bob');
      await _settle();
      final heard = await alice.store.find(group.id, fromBob.id);
      expect(heard, isNotNull);

      await expectLater(
        alice.groups.sendText(group.id, 'Reply to Bob', replyToId: heard!.id),
        throwsArgumentError,
      );
      final own = await alice.groups.sendText(group.id, 'Mine');
      final reply = await alice.groups.sendText(
        group.id,
        'Reply to myself',
        replyToId: own.id,
      );
      expect(reply.replyTo?.id, own.id);
    });

    test('a member who left keeps its history read-only, and the group stays '
        'active for the two who remain', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);

      final before = await alice.groups.sendText(group.id, 'Before');
      await _settle();
      final carolDevices = net.managers.remove(_carol)!;
      final offline = await alice.groups.sendText(group.id, 'While away');
      await _settle();
      expect(
        (await alice.store.find(group.id, offline.id))!.memberStates[_carol],
        ChatState.sending,
      );

      net.managers[_carol] = carolDevices;
      now = now.add(const Duration(seconds: 30));
      await alice.tick();
      await _settle();
      expect(
        (await alice.store.find(group.id, offline.id))!.memberStates[_carol],
        ChatState.delivered,
        reason: 'the relay copy goes out again when the member returns',
      );
      expect((await carol.store.find(group.id, before.id))!.authorId, _alice);

      expect(await carol.groups.leave(group.id), isTrue);
      await _settle();
      expect(
        (await held(alice, group.id)).memberOf(_carol)!.state,
        MemberState.left,
      );
      expect(
        (await held(bob, group.id)).memberOf(_carol)!.state,
        MemberState.left,
      );

      final toCarolBefore = sentTo(_carol, 'group.text');
      await alice.groups.sendText(group.id, 'Just the two of us');
      await _settle();
      expect(sentTo(_bob, 'group.text'), 3);
      expect(
        sentTo(_carol, 'group.text'),
        toCarolBefore,
        reason: 'nothing goes to the member who left',
      );
      expect(ChatGroups.isActive(await held(alice, group.id)), isTrue);
      expect(ChatGroups.isActive(await held(bob, group.id)), isTrue);
      expect(ChatGroups.isActive(await held(carol, group.id)), isFalse);
      await expectLater(
        carol.groups.sendText(group.id, 'Still me'),
        throwsArgumentError,
      );
    });
  });

  group('invites that wait for an answer', () {
    test('an invite is sent again every 30 seconds, and a member who comes '
        'back in time gets it and can accept', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      device(_carol, contacts: {_alice, _bob});
      final bobDevices = net.managers.remove(_bob)!;

      final group = await alice.groups.create(
        name: 'Trip',
        invitees: [_bob, _carol],
      );
      await _settle();
      expect(sentTo(_bob, 'group.invite'), 1);

      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 30));
        await alice.tick();
        await _settle();
      }
      expect(sentTo(_bob, 'group.invite'), 5);

      net.managers[_bob] = bobDevices;
      now = now.add(const Duration(seconds: 30));
      await alice.tick();
      await _settle();
      expect(await bob.groups.accept(group.id), GroupJoinResult.joined);
    });

    test('a member with a live session gets the invite as a direct frame, as '
        'well as through the relay', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      device(_carol, contacts: {_alice, _bob});
      await alice.sendText(_bob, 'open the chat');
      await _settle();

      final group = await alice.groups.create(
        name: 'Trip',
        invitees: [_bob, _carol],
      );
      await _settle();

      final direct = net.rtcs[_alice]!
          .expand((rtc) => rtc.sentFrames)
          .map(ChatFrames.decode)
          .whereType<GroupInviteFrame>();
      expect(direct.map((f) => f.group), contains(group.id));
      expect(sentTo(_bob, 'group.invite'), 1);
      expect(await bob.store.group(group.id), isNotNull);
    });

    test('an invite nobody answers in 15 minutes expires, and is not sent '
        'again', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      device(_bob, contacts: {_alice, _carol});
      device(_carol, contacts: {_alice, _bob});
      net.managers.remove(_bob);
      final group = await alice.groups.create(
        name: 'Trip',
        invitees: [_bob, _carol],
      );
      await _settle();

      now = now.add(const Duration(minutes: 16));
      await alice.tick();
      await _settle();
      expect(
        (await held(alice, group.id)).memberOf(_bob)!.state,
        MemberState.expired,
      );
      final sent = sentTo(_bob, 'group.invite');
      now = now.add(const Duration(minutes: 1));
      await alice.tick();
      await _settle();
      expect(sentTo(_bob, 'group.invite'), sent);
    });
  });

  group('pending lists', () {
    test('controls held for a member without a session hold at most 100, and '
        'expire after 7 days', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);
      net.managers.remove(_bob);

      for (var i = 0; i < 101; i++) {
        final message = await alice.groups.sendText(group.id, 'Message $i');
        await alice.groups.react(group.id, message.id, '\u{1F44D}');
      }
      await _settle();

      expect(
        await alice.store.pendingControls(
          group.id,
          memberId: _bob,
          clock: () => now,
        ),
        hasLength(100),
      );
      now = now.add(const Duration(days: 8));
      expect(
        await alice.store.pendingControls(
          group.id,
          memberId: _bob,
          clock: () => now,
        ),
        isEmpty,
      );
    });

    test('an answer waiting for a member without a session expires after 7 '
        'days', () async {
      final alice = device(_alice, contacts: {_bob, _carol});
      final bob = device(_bob, contacts: {_alice, _carol});
      final carol = device(_carol, contacts: {_alice, _bob});
      final group = await threeMade(alice: alice, bob: bob, carol: carol);

      expect(await bob.groups.leave(group.id), isTrue);
      await _settle();
      final waiting = await bob.store.pendingGroupStates(
        group.id,
        memberId: _carol,
        clock: () => now,
      );
      expect(waiting.map((f) => f.kind), contains(GroupStateKind.leave));
      now = now.add(const Duration(days: 8));
      expect(
        await bob.store.pendingGroupStates(
          group.id,
          memberId: _carol,
          clock: () => now,
        ),
        isEmpty,
      );
    });
  });
}
