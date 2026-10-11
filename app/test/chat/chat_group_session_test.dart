import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_group.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/identity_store.dart';

/// A Sotto ID: 32 bytes of signing key, as base64url.
String _member(int n) => b64Encode(List<int>.filled(32, n));

/// A group id or message id: 16 bytes, as base64url.
String _id(int n) => b64Encode(List<int>.filled(16, n));

/// This device is [_self]. Its group is [_group], with [_bob], [_carol] and
/// [_dave] (who is not in it). The clock of every session reads [_now].
final _self = _member(1);
final _bob = _member(2);
final _carol = _member(3);
final _dave = _member(4);
final _group = _id(60);
final _now = DateTime.utc(2026, 10, 9, 12);
final _ts = _now.millisecondsSinceEpoch;

/// The group as this device holds it: itself and two others, each in the
/// given state. Invited at [_ts].
ChatGroup _groupWith({
  MemberState self = MemberState.accepted,
  MemberState bob = MemberState.accepted,
  MemberState carol = MemberState.accepted,
}) => ChatGroup(
  id: _group,
  name: 'Trip',
  selfId: _self,
  createdAt: _ts,
  members: [
    GroupMember(id: _self, state: self, invitedAt: _ts),
    GroupMember(id: _bob, state: bob, invitedAt: _ts),
    GroupMember(id: _carol, state: carol, invitedAt: _ts),
  ],
);

/// One end of an in-memory data channel. Frames sent here arrive at [peer].
class _Link implements ChatTransport {
  final _incoming = StreamController<String>();
  final _incomingBinary = StreamController<Uint8List>();
  _Link? peer;
  bool closed = false;

  /// Every text frame this end has sent, in order.
  final sentFrames = <String>[];

  @override
  bool send(String frame) {
    if (closed || peer == null || peer!.closed) return false;
    sentFrames.add(frame);
    peer!._incoming.add(frame);
    return true;
  }

  @override
  bool sendBinary(Uint8List data) => false;

  @override
  Future<int> bufferedAmountNow() async => 0;

  @override
  int get bufferedAmount => 0;

  @override
  Stream<String> get frames => _incoming.stream;

  @override
  Stream<Uint8List> get binaryFrames => _incomingBinary.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_incomingBinary.isClosed) await _incomingBinary.close();
  }
}

/// Every feature a peer with groups lists in its hello.
final _allFeatures = {...ChatFrames.features, ChatFrames.featureGroups};

/// Lets queued events and futures run.
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// This device's session with [contact], over a channel whose far end the
/// test drives with [receive], as the member would.
class _Device {
  _Device(
    this.contact, {
    required this.groups,
    ChatStore? store,
    this.isContact,
  }) : store = store ?? ChatStore(MemorySecretStore());

  final String contact;
  final bool groups;
  final ChatStore store;
  final bool Function()? isContact;
  final _near = _Link();
  final _far = _Link();
  late final ChatSession session;
  final events = <ChatSessionEvent>[];

  void start({List<ChatMessage> resend = const []}) {
    _near.peer = _far;
    _far.peer = _near;
    session = ChatSession(
      contactId: contact,
      transport: _near,
      store: store,
      clock: () => _now,
      groupsEnabled: groups,
      isContact: isContact,
    );
    session.events.listen(events.add);
    unawaited(session.start(resend: resend));
  }

  /// Sends [frame] from the far end, as the member would.
  void receive(ChatFrame frame) => _far.send(ChatFrames.encode(frame));

  /// The frames this device has written to the channel, decoded.
  List<ChatFrame> get written => [
    for (final raw in _near.sentFrames) ChatFrames.decode(raw),
  ];

  Iterable<T> ofType<T extends ChatSessionEvent>() => events.whereType<T>();
}

/// A device with [group] held (when given), its session with [contact] started
/// and the member's hello received.
Future<_Device> _open(
  String contact, {
  ChatGroup? group,
  bool groups = true,
}) async {
  final device = _Device(contact, groups: groups);
  if (group != null) await device.store.saveGroup(group);
  device.start();
  device.receive(HelloFrame(features: _allFeatures));
  await _settle();
  return device;
}

/// A message held in [_group] from [author], for a test to start from. It is
/// this device's own when [author] is [_self].
ChatMessage _held(String id, String author, {String text = 'held', int? ts}) =>
    ChatMessage(
      id: id,
      contactId: _group,
      groupId: _group,
      authorId: author,
      outgoing: author == _self,
      ts: ts ?? _ts,
      text: text,
      state: author == _self ? ChatState.delivered : ChatState.received,
      read: author == _self,
    );

void main() {
  group('group messages from a member', () {
    test('a message from a member is kept under its group and acknowledged with it', () async {
      final device = await _open(_bob, group: _groupWith());

      device.receive(
        GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'hello'),
      );
      await _settle();

      final stored = await device.store.find(_group, _id(1));
      expect(stored!.text, 'hello');
      expect(stored.groupId, _group);
      expect(stored.authorId, _bob);
      expect(stored.outgoing, isFalse);
      expect(device.ofType<MessageReceived>().single.message.id, _id(1));
      expect(await device.store.messages(_bob), isEmpty);
      expect(device.written.whereType<AckFrame>().single.group, _group);
    });

    test(
      'a message from someone who is not a member is dropped, with no ack',
      () async {
        final device = await _open(_dave, group: _groupWith());

        device.receive(
          GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'hi'),
        );
        await _settle();

        expect(await device.store.find(_group, _id(1)), isNull);
        expect(device.ofType<MessageReceived>(), isEmpty);
        expect(device.written.whereType<AckFrame>(), isEmpty);
        expect(device.session.isEnded, isFalse);
      },
    );

    test(
      'a message from a member who has not accepted on this device is dropped',
      () async {
        final device = await _open(
          _carol,
          group: _groupWith(carol: MemberState.invited),
        );

        device.receive(
          GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'early'),
        );
        await _settle();

        expect(await device.store.find(_group, _id(1)), isNull);
        expect(device.written.whereType<AckFrame>(), isEmpty);
      },
    );

    test(
      'a message for a group this device does not hold is dropped',
      () async {
        final device = await _open(_bob);

        device.receive(
          GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'lost'),
        );
        await _settle();

        expect(await device.store.messages(_group), isEmpty);
        expect(device.written.whereType<AckFrame>(), isEmpty);
      },
    );

    test('a message for a group this device has left is dropped', () async {
      final device = await _open(
        _bob,
        group: _groupWith(self: MemberState.left),
      );

      device.receive(
        GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'after'),
      );
      await _settle();

      expect(await device.store.messages(_group), isEmpty);
      expect(device.written.whereType<AckFrame>(), isEmpty);
    });

    test(
      'a message that arrives twice is stored once, and acknowledged each time',
      () async {
        final device = await _open(_bob, group: _groupWith());
        final frame = GroupMsgFrame(
          id: _id(1),
          ts: _ts,
          group: _group,
          text: 'once',
        );

        device.receive(frame);
        device.receive(frame);
        await _settle();

        expect(await device.store.messages(_group), hasLength(1));
        expect(device.ofType<MessageReceived>(), hasLength(1));
        expect(device.written.whereType<AckFrame>(), hasLength(2));
      },
    );

    test(
      'a message whose id the group already holds keeps the author it has',
      () async {
        final device = await _open(_bob, group: _groupWith());
        await device.store.add(_held(_id(1), _carol, text: 'from carol'));

        device.receive(
          GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'from bob'),
        );
        await _settle();

        final stored = await device.store.messages(_group);
        expect(stored, hasLength(1));
        expect(stored.single.authorId, _carol);
        expect(stored.single.text, 'from carol');
        expect(device.ofType<MessageReceived>(), isEmpty);
      },
    );

    test('a quote in a group message is kept only when the sender wrote the quoted message', () async {
      final device = await _open(_bob, group: _groupWith());
      await device.store.add(_held(_id(1), _carol, text: 'carol said'));
      await device.store.add(_held(_id(2), _bob, text: 'bob said'));

      device.receive(
        GroupMsgFrame(
          id: _id(3),
          ts: _ts,
          group: _group,
          text: 'quoting carol',
          reply: (id: _id(1), text: 'carol said'),
        ),
      );
      device.receive(
        GroupMsgFrame(
          id: _id(4),
          ts: _ts,
          group: _group,
          text: 'quoting bob',
          reply: (id: _id(2), text: 'bob said'),
        ),
      );
      await _settle();

      expect((await device.store.find(_group, _id(3)))!.replyTo, isNull);
      final quoting = (await device.store.find(_group, _id(4)))!;
      expect(quoting.replyTo?.id, _id(2));
      expect(quoting.replyTo?.text, 'bob said');
    });

    test('with groups off, a group message is ignored', () async {
      final device = await _open(_bob, group: _groupWith(), groups: false);

      device.receive(
        GroupMsgFrame(id: _id(1), ts: _ts, group: _group, text: 'off'),
      );
      await _settle();

      expect(await device.store.messages(_group), isEmpty);
      expect(device.written.whereType<AckFrame>(), isEmpty);
      expect(device.session.isEnded, isFalse);
    });

    test('the group feature is listed in hello only with groups on', () async {
      final on = await _open(_bob, group: _groupWith());
      final off = await _open(_bob, group: _groupWith(), groups: false);

      expect(
        on.written.whereType<HelloFrame>().single.features,
        contains(ChatFrames.featureGroups),
      );
      expect(
        off.written.whereType<HelloFrame>().single.features,
        isNot(contains(ChatFrames.featureGroups)),
      );
    });
  });

  group('reactions, edits, deletes and receipts in a group', () {
    test('a reaction from a member is kept under the member id', () async {
      final device = await _open(_bob, group: _groupWith());
      await device.store.add(_held(_id(1), _self));

      device.receive(
        ReactFrame(id: _id(1), emoji: '👍', ts: _ts, group: _group),
      );
      await _settle();

      final message = (await device.store.find(_group, _id(1)))!;
      expect(message.reactions, {_bob: '👍'});
      expect(device.ofType<MessageChanged>().single.group, _group);
    });

    test('a reaction from someone who is not a member is ignored', () async {
      final device = await _open(_dave, group: _groupWith());
      await device.store.add(_held(_id(1), _self));

      device.receive(
        ReactFrame(id: _id(1), emoji: '👍', ts: _ts, group: _group),
      );
      await _settle();

      expect((await device.store.find(_group, _id(1)))!.reactions, isEmpty);
    });

    test('an edit from the author applies to its own message', () async {
      final device = await _open(_carol, group: _groupWith());
      await device.store.add(_held(_id(1), _carol, text: 'first'));

      device.receive(
        EditFrame(id: _id(1), ts: _ts, text: 'second', group: _group),
      );
      await _settle();

      final message = (await device.store.find(_group, _id(1)))!;
      expect(message.text, 'second');
      expect(message.editedAt, _ts);
    });

    test(
      'an edit or delete of a message another member wrote is ignored',
      () async {
        final device = await _open(_bob, group: _groupWith());
        await device.store.add(_held(_id(1), _carol, text: 'carol'));

        device.receive(
          EditFrame(id: _id(1), ts: _ts, text: 'bob', group: _group),
        );
        device.receive(DeleteFrame(id: _id(1), ts: _ts, group: _group));
        await _settle();

        final message = (await device.store.find(_group, _id(1)))!;
        expect(message.text, 'carol');
        expect(message.deletedForAll, isFalse);
        expect(device.ofType<MessageChanged>(), isEmpty);
      },
    );

    test('an edit of this device\'s own message is ignored', () async {
      final device = await _open(_carol, group: _groupWith());
      await device.store.add(_held(_id(1), _self, text: 'mine'));

      device.receive(
        EditFrame(id: _id(1), ts: _ts, text: 'changed', group: _group),
      );
      await _settle();

      expect((await device.store.find(_group, _id(1)))!.text, 'mine');
    });

    test(
      'an edit more than fifteen minutes after its message is ignored',
      () async {
        final device = await _open(_carol, group: _groupWith());
        final sent = _ts - const Duration(minutes: 20).inMilliseconds;
        await device.store.add(_held(_id(1), _carol, text: 'old', ts: sent));

        device.receive(
          EditFrame(id: _id(1), ts: _ts, text: 'late', group: _group),
        );
        await _settle();

        expect((await device.store.find(_group, _id(1)))!.text, 'old');
      },
    );

    test(
      'a delete from the author clears the text and keeps the record',
      () async {
        final device = await _open(_carol, group: _groupWith());
        await device.store.add(_held(_id(1), _carol, text: 'gone'));

        device.receive(DeleteFrame(id: _id(1), ts: _ts, group: _group));
        await _settle();

        final message = (await device.store.find(_group, _id(1)))!;
        expect(message.deletedForAll, isTrue);
        expect(message.text, isEmpty);
      },
    );

    test('a member read receipt marks this device\'s message read under the member', () async {
      final device = await _open(_bob, group: _groupWith());
      await device.store.add(_held(_id(1), _self));

      device.receive(ReadFrame(ids: [_id(1)], group: _group));
      await _settle();

      final message = (await device.store.find(_group, _id(1)))!;
      expect(message.memberStates, {_bob: ChatState.read});
      expect(message.state, ChatState.delivered);
      expect(device.ofType<MessagesRead>().single.group, _group);
    });

    test(
      'a read receipt for a message this device did not write is ignored',
      () async {
        final device = await _open(_bob, group: _groupWith());
        await device.store.add(_held(_id(1), _carol));

        device.receive(ReadFrame(ids: [_id(1)], group: _group));
        await _settle();

        expect(
          (await device.store.find(_group, _id(1)))!.memberStates,
          isEmpty,
        );
        expect(device.ofType<MessagesRead>(), isEmpty);
      },
    );

    test('a read receipt goes only to the author of the message', () async {
      final toCarol = await _open(_carol, group: _groupWith());
      final toBob = await _open(_bob, group: _groupWith());
      await toCarol.store.add(_held(_id(1), _carol));

      await toCarol.session.sendGroupReadReceipts(_group, [_id(1)]);
      await toBob.session.sendGroupReadReceipts(_group, [_id(1)]);
      await _settle();

      final sent = toCarol.written.whereType<ReadFrame>().single;
      expect(sent.ids, [_id(1)]);
      expect(sent.group, _group);
      expect(toBob.written.whereType<ReadFrame>(), isEmpty);
    });

    test(
      'a read receipt asked for before the author is ready is sent when it is',
      () async {
        final device = _Device(_carol, groups: true);
        await device.store.saveGroup(_groupWith());
        await device.store.add(_held(_id(1), _carol));
        device.start();
        await _settle();

        await device.session.sendGroupReadReceipts(_group, [_id(1)]);
        expect(device.written.whereType<ReadFrame>(), isEmpty);

        device.receive(const HelloFrame(features: {'groups'}));
        await _settle();

        final sent = device.written.whereType<ReadFrame>().single;
        expect(sent.ids, [_id(1)]);
        expect(sent.group, _group);
      },
    );
  });

  group('answers and leaves of members', () {
    /// A group in which bob is [bob] (invited at [_ts] by default).
    ChatGroup withBob(MemberState bob) => _groupWith(bob: bob);

    GroupStateFrame answer(GroupStateKind kind, int ts) =>
        GroupStateFrame(kind: kind, group: _group, ts: ts);

    test(
      'an accept inside the window accepts the member on this device',
      () async {
        final device = await _open(_bob, group: withBob(MemberState.invited));

        device.receive(answer(GroupStateKind.accept, _ts + 60 * 1000));
        await _settle();

        final group = (await device.store.group(_group))!;
        expect(group.memberOf(_bob)!.state, MemberState.accepted);
        expect(device.ofType<GroupStateChanged>().single.group, _group);
      },
    );

    test('an accept after the window leaves the member expired', () async {
      final device = await _open(_bob, group: withBob(MemberState.invited));

      device.receive(
        answer(
          GroupStateKind.accept,
          _ts + const Duration(minutes: 21).inMilliseconds,
        ),
      );
      await _settle();

      expect(
        (await device.store.group(_group))!.memberOf(_bob)!.state,
        MemberState.expired,
      );
    });

    test(
      'a decline is applied once, and a later accept does not undo it',
      () async {
        final device = await _open(_bob, group: withBob(MemberState.invited));

        device.receive(answer(GroupStateKind.decline, _ts));
        device.receive(answer(GroupStateKind.decline, _ts));
        device.receive(answer(GroupStateKind.accept, _ts));
        await _settle();

        expect(
          (await device.store.group(_group))!.memberOf(_bob)!.state,
          MemberState.declined,
        );
        expect(device.ofType<GroupStateChanged>(), hasLength(1));
      },
    );

    test(
      'a decline dated before the invite it would answer is ignored',
      () async {
        final device = await _open(_bob, group: withBob(MemberState.invited));

        device.receive(answer(GroupStateKind.decline, _ts - 1000));
        await _settle();

        expect(
          (await device.store.group(_group))!.memberOf(_bob)!.state,
          MemberState.invited,
        );
        expect(device.ofType<GroupStateChanged>(), isEmpty);
      },
    );

    test('a leave from an accepted member is applied once', () async {
      final device = await _open(_bob, group: _groupWith());

      device.receive(answer(GroupStateKind.leave, _ts));
      device.receive(answer(GroupStateKind.leave, _ts));
      await _settle();

      expect(
        (await device.store.group(_group))!.memberOf(_bob)!.state,
        MemberState.left,
      );
      expect(device.ofType<GroupStateChanged>(), hasLength(1));
    });

    test('an answer from someone who is not a member is ignored', () async {
      final device = await _open(_dave, group: _groupWith());

      device.receive(answer(GroupStateKind.leave, _ts));
      await _settle();

      expect(device.ofType<GroupStateChanged>(), isEmpty);
      expect((await device.store.group(_group))!.memberOf(_dave), isNull);
    });

    test(
      'a pending answer is sent once the member is ready, and then forgotten',
      () async {
        final device = _Device(_bob, groups: true);
        await device.store.saveGroup(_groupWith());
        await device.store.queueGroupState(
          _group,
          _bob,
          answer(GroupStateKind.leave, _ts),
          clock: () => _now,
        );
        device.start();
        await _settle();

        expect(device.written.whereType<GroupStateFrame>(), isEmpty);

        device.receive(const HelloFrame(features: {'groups'}));
        await _settle();

        final sent = device.written.whereType<GroupStateFrame>().single;
        expect(sent.kind, GroupStateKind.leave);
        expect(sent.group, _group);
        expect(
          await device.store.pendingGroupStates(
            _group,
            memberId: _bob,
            clock: () => _now,
          ),
          isEmpty,
        );
      },
    );

    test('with groups off, a pending answer is not sent', () async {
      final device = _Device(_bob, groups: false);
      await device.store.saveGroup(_groupWith());
      await device.store.queueGroupState(
        _group,
        _bob,
        answer(GroupStateKind.leave, _ts),
        clock: () => _now,
      );
      device.start();
      device.receive(const HelloFrame(features: {'groups'}));
      await _settle();

      expect(device.written.whereType<GroupStateFrame>(), isEmpty);
      expect(
        await device.store.pendingGroupStates(
          _group,
          memberId: _bob,
          clock: () => _now,
        ),
        hasLength(1),
      );
    });

    test(
      'a reaction to a member waits until the member has stored the message',
      () async {
        final device = _Device(_bob, groups: true);
        await device.store.saveGroup(_groupWith());
        await device.store.add(
          _held(
            _id(1),
            _self,
          ).copyWith(memberStates: {_bob: ChatState.sending}),
        );
        await device.store.queueControl(
          _group,
          ReactFrame(id: _id(1), emoji: '👍', ts: _ts, group: _group),
          memberId: _bob,
          clock: () => _now,
        );
        device.start();
        device.receive(
          HelloFrame(
            features: {...ChatFrames.features, ChatFrames.featureGroups},
          ),
        );
        await _settle();

        expect(device.written.whereType<ReactFrame>(), isEmpty);

        await device.store.setState(
          _group,
          _id(1),
          ChatState.delivered,
          memberId: _bob,
        );
        await device.session.flushControls();
        await _settle();

        final sent = device.written.whereType<ReactFrame>().single;
        expect(sent.emoji, '👍');
        expect(sent.group, _group);
      },
    );
  });

  group('group messages this device sends', () {
    /// This device's outgoing message [n] in the group, as it is stored before
    /// it is sent.
    ChatMessage outgoing(int n, {ChatReply? replyTo}) => _held(
      _id(n),
      _self,
      text: 'held',
    ).copyWith(state: ChatState.sending, replyTo: replyTo);

    test('a group message goes to a member as a group frame, and its ack marks it delivered for that member', () async {
      final device = await _open(_bob, group: _groupWith());
      final message = outgoing(1);
      await device.store.add(message);

      await device.session.sendToGroup(message);
      await _settle();

      final sent = device.written.whereType<GroupMsgFrame>().single;
      expect(sent.id, _id(1));
      expect(sent.group, _group);
      expect(sent.text, 'held');
      expect((await device.store.find(_group, _id(1)))!.memberStates, {
        _bob: ChatState.sending,
      });

      device.receive(AckFrame(id: _id(1), group: _group));
      await _settle();

      final stored = (await device.store.find(_group, _id(1)))!;
      expect(stored.memberStates, {_bob: ChatState.delivered});
      expect(stored.state, ChatState.sending);
      expect(device.ofType<MessageDelivered>().single.group, _group);
    });

    test('each member\'s copy is acknowledged on its own', () async {
      final store = ChatStore(MemorySecretStore());
      await store.saveGroup(_groupWith());
      final toBob = _Device(_bob, groups: true, store: store)..start();
      final toCarol = _Device(_carol, groups: true, store: store)..start();
      toBob.receive(HelloFrame(features: _allFeatures));
      toCarol.receive(HelloFrame(features: _allFeatures));
      final message = outgoing(1);
      await store.add(message);

      await toBob.session.sendToGroup(message);
      await toCarol.session.sendToGroup(message);
      toBob.receive(AckFrame(id: _id(1), group: _group));
      await _settle();

      expect((await store.find(_group, _id(1)))!.memberStates, {
        _bob: ChatState.delivered,
        _carol: ChatState.sending,
      });
    });

    test('a copy waits while the member cannot take group frames', () async {
      final device = _Device(_bob, groups: true);
      await device.store.saveGroup(_groupWith());
      final message = outgoing(1);
      await device.store.add(message);
      device.start();
      device.receive(const HelloFrame());
      await _settle();

      await device.session.sendToGroup(message);
      await _settle();

      expect(device.written.whereType<GroupMsgFrame>(), isEmpty);
      expect((await device.store.find(_group, _id(1)))!.memberStates, {
        _bob: ChatState.sending,
      });
    });

    test('with groups off, nothing is sent to a group', () async {
      final device = await _open(_bob, group: _groupWith(), groups: false);
      final message = outgoing(1);
      await device.store.add(message);

      await device.session.sendToGroup(message);
      await _settle();

      expect(device.written.whereType<GroupMsgFrame>(), isEmpty);
      expect((await device.store.find(_group, _id(1)))!.memberStates, isEmpty);
    });

    test(
      'a reply quoting a message that is not this device\'s own is refused',
      () async {
        final device = await _open(_bob, group: _groupWith());
        await device.store.add(_held(_id(1), _carol, text: 'carol said'));
        final reply = outgoing(2, replyTo: (id: _id(1), text: 'carol said'));
        await device.store.add(reply);

        await expectLater(
          device.session.sendToGroup(reply),
          throwsArgumentError,
        );
        await _settle();
        expect(device.written.whereType<GroupMsgFrame>(), isEmpty);
      },
    );

    test(
      'a reply quoting this device\'s own message goes with its quote',
      () async {
        final device = await _open(_bob, group: _groupWith());
        await device.store.add(_held(_id(1), _self, text: 'mine'));
        final reply = outgoing(2, replyTo: (id: _id(1), text: 'mine'));
        await device.store.add(reply);

        await device.session.sendToGroup(reply);
        await _settle();

        final sent = device.written.whereType<GroupMsgFrame>().single;
        expect(sent.reply?.id, _id(1));
        expect(sent.reply?.text, 'mine');
      },
    );

    test('a copy not acknowledged when its session ends is not sent, for that member only', () async {
      final store = ChatStore(MemorySecretStore());
      await store.saveGroup(_groupWith());
      final toBob = _Device(_bob, groups: true, store: store)..start();
      final toCarol = _Device(_carol, groups: true, store: store)..start();
      toBob.receive(HelloFrame(features: _allFeatures));
      toCarol.receive(HelloFrame(features: _allFeatures));
      final message = outgoing(1);
      await store.add(message);
      await toBob.session.sendToGroup(message);
      await toCarol.session.sendToGroup(message);
      await _settle();

      await toBob.session.close();
      await _settle();

      expect((await store.find(_group, _id(1)))!.memberStates, {
        _bob: ChatState.notSent,
        _carol: ChatState.sending,
      });
      expect(toBob.ofType<MessageNotSent>().single.group, _group);
    });

    test(
      'a copy kept from an earlier session is sent when the member is ready',
      () async {
        final device = _Device(_bob, groups: true);
        await device.store.saveGroup(_groupWith());
        final message = outgoing(1);
        await device.store.add(message);
        device.start(resend: [message]);
        await _settle();
        expect(device.written.whereType<GroupMsgFrame>(), isEmpty);

        device.receive(HelloFrame(features: _allFeatures));
        await _settle();

        expect(device.written.whereType<GroupMsgFrame>().single.id, _id(1));
        expect((await device.store.find(_group, _id(1)))!.memberStates, {
          _bob: ChatState.sending,
        });
      },
    );
  });

  group('a member removed as a contact, or who has left', () {
    test('gets no group message, control or read receipt after removal, with its session open', () async {
      var contact = true;
      final store = ChatStore(MemorySecretStore());
      await store.saveGroup(_groupWith());
      await store.add(_held(_id(2), _bob, text: 'from bob'));
      final device = _Device(
        _bob,
        groups: true,
        store: store,
        isContact: () => contact,
      )..start();
      device.receive(HelloFrame(features: _allFeatures));
      await _settle();

      contact = false;
      final mine = _held(_id(1), _self, text: 'held');
      await store.add(mine);
      await device.session.sendToGroup(mine);
      await store.queueControl(
        _group,
        ReactFrame(id: _id(2), emoji: 'x', ts: _ts, group: _group),
        memberId: _bob,
        clock: () => _now,
      );
      await device.session.flushControls();
      await device.session.sendGroupReadReceipts(_group, [_id(2)]);
      await _settle();

      expect(device.written.whereType<GroupMsgFrame>(), isEmpty);
      expect(device.written.whereType<ReactFrame>(), isEmpty);
      expect(device.written.whereType<ReadFrame>(), isEmpty);
    });

    test('a group answer from a member removed as a contact ends the session and changes nothing', () async {
      var contact = true;
      final store = ChatStore(MemorySecretStore());
      await store.saveGroup(_groupWith());
      final device = _Device(
        _bob,
        groups: true,
        store: store,
        isContact: () => contact,
      )..start();
      device.receive(HelloFrame(features: _allFeatures));
      await _settle();

      contact = false;
      device.receive(
        GroupStateFrame(kind: GroupStateKind.leave, group: _group, ts: _ts),
      );
      await _settle();

      expect(
        (await store.group(_group))!.memberOf(_bob)!.state,
        MemberState.accepted,
      );
      expect(device.session.isEnded, isTrue);
    });

    test(
      'a copy queued before a member left is not sent to it when it comes back',
      () async {
        final store = ChatStore(MemorySecretStore());
        await store.saveGroup(_groupWith());
        final device = _Device(_bob, groups: true, store: store)..start();
        device.receive(HelloFrame(features: ChatFrames.features));
        await _settle();
        final message = _held(_id(1), _self, text: 'held');
        await store.add(message);
        await device.session.sendToGroup(message);
        await _settle();
        expect(device.written.whereType<GroupMsgFrame>(), isEmpty);

        device.receive(
          GroupStateFrame(kind: GroupStateKind.leave, group: _group, ts: _ts),
        );
        await _settle();
        device.receive(HelloFrame(features: _allFeatures));
        await _settle();

        expect(device.written.whereType<GroupMsgFrame>(), isEmpty);
      },
    );
  });

  group('a reply quote in a group', () {
    test(
      'quoting a message this device does not hold arrives with no quote',
      () async {
        final device = await _open(_bob, group: _groupWith());
        device.receive(
          GroupMsgFrame(
            id: _id(3),
            ts: _ts,
            group: _group,
            text: 'quoting a message not held here',
            reply: (id: _id(9), text: 'unknown'),
          ),
        );
        await _settle();

        final stored = (await device.store.find(_group, _id(3)))!;
        expect(stored.text, 'quoting a message not held here');
        expect(stored.replyTo, isNull);
      },
    );
  });
}
