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

/// Lets queued events and futures run.
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// This device's session with [contact], over a channel whose far end the
/// test drives with [receive], as the member would.
class _Device {
  _Device(this.contact, {required this.groups, ChatStore? store})
    : store = store ?? ChatStore(MemorySecretStore());

  final String contact;
  final bool groups;
  final ChatStore store;
  final _near = _Link();
  final _far = _Link();
  late final ChatSession session;
  final events = <ChatSessionEvent>[];

  void start() {
    _near.peer = _far;
    _far.peer = _near;
    session = ChatSession(
      contactId: contact,
      transport: _near,
      store: store,
      clock: () => _now,
      groupsEnabled: groups,
    );
    session.events.listen(events.add);
    unawaited(session.start());
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
  device.receive(const HelloFrame(features: {'groups'}));
  await _settle();
  return device;
}

/// A message held in [_group] from [author], for a test to start from.
ChatMessage _held(String id, String author, {String text = 'held'}) =>
    ChatMessage(
      id: id,
      contactId: _group,
      groupId: _group,
      authorId: author,
      outgoing: author == _self,
      ts: _ts,
      text: text,
      state: ChatState.received,
      read: false,
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
}
