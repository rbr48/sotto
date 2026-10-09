import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_signalling.dart';
import 'package:sotto/crypto/encoding.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

final _t0 = DateTime.utc(2026, 10, 9, 12);

void main() {
  late int counter;
  late ChatSignalling mine;

  /// This device is "mmm"; "bob" is a contact, "eve" is not.
  setUp(() {
    counter = 0;
    mine = ChatSignalling(
      myId: 'mmm',
      isContact: (id) => id == 'bob',
      newId: () => _id(++counter),
    );
  });

  List<ChatAction> handle(
    String from,
    String type, {
    Map<String, dynamic> body = const {},
    String? callId,
    DateTime? now,
  }) => mine.handle(
    from: from,
    type: type,
    body: body,
    callId: callId,
    now: now ?? _t0,
  );

  test('opening sends chat.open with a new session id', () {
    final actions = mine.open('bob', _t0);
    expect(actions, hasLength(1));
    final send = actions.single as SendEnvelope;
    expect(send.to, 'bob');
    expect(send.type, 'chat.open');
    expect(send.callId, _id(1));
    expect(mine.isOpening('bob'), isTrue);
    // A second open while one is waiting does nothing.
    expect(mine.open('bob', _t0), isEmpty);
  });

  test('the first answer wins: taken is sent and the opener is ready', () {
    mine.open('bob', _t0);
    final actions = handle(
      'bob',
      'chat.accept',
      body: {'tag': _id(50)},
      callId: _id(1),
    );
    expect(actions[0], isA<SendEnvelope>());
    final taken = actions[0] as SendEnvelope;
    expect(taken.type, 'chat.taken');
    expect(taken.body, {'tag': _id(50)});
    final ready = actions[1] as SessionReady;
    expect(ready.offerer, isTrue);
    expect(ready.contact, 'bob');
    expect(ready.tag, _id(50));
    expect(mine.isOpening('bob'), isFalse);

    // A later answer from another device is ignored.
    expect(
      handle('bob', 'chat.accept', body: {'tag': _id(51)}, callId: _id(1)),
      isEmpty,
    );
  });

  test('an answer for another session is ignored', () {
    mine.open('bob', _t0);
    expect(
      handle('bob', 'chat.accept', body: {'tag': _id(50)}, callId: _id(99)),
      isEmpty,
    );
    expect(mine.isOpening('bob'), isTrue);
  });

  test('a decline ends the open, with its reason', () {
    mine.open('bob', _t0);
    final actions = handle(
      'bob',
      'chat.decline',
      body: {'reason': 'not-contact'},
      callId: _id(1),
    );
    expect(actions.single, isA<OpenFailed>());
    expect((actions.single as OpenFailed).reason, 'not-contact');
    expect(mine.isOpening('bob'), isFalse);
  });

  test('an open with no answer fails after the open timeout', () {
    mine.open('bob', _t0);
    expect(mine.tick(_t0.add(const Duration(seconds: 19))), isEmpty);
    final failed = mine.tick(_t0.add(const Duration(seconds: 20)));
    expect((failed.single as OpenFailed).reason, 'no-answer');
    expect(mine.isOpening('bob'), isFalse);
  });

  test('a chat from someone who is not a contact is declined', () {
    final actions = handle('eve', 'chat.open', callId: _id(7));
    final decline = actions.single as SendEnvelope;
    expect(decline.to, 'eve');
    expect(decline.type, 'chat.decline');
    expect(decline.body, {'reason': 'not-contact'});
    expect(decline.callId, _id(7));
  });

  test(
    'a contact opening a chat gets an accept with a tag for this device',
    () {
      final actions = handle('bob', 'chat.open', callId: _id(7));
      final accept = actions.single as SendEnvelope;
      expect(accept.type, 'chat.accept');
      expect(accept.to, 'bob');
      expect(accept.callId, _id(7));
      expect(accept.body['tag'], _id(1));
    },
  );

  test('a device that wins is ready to take the offer', () {
    handle('bob', 'chat.open', callId: _id(7));
    final actions = handle(
      'bob',
      'chat.taken',
      body: {'tag': _id(1)},
      callId: _id(7),
    );
    final ready = actions.single as SessionReady;
    expect(ready.offerer, isFalse);
    expect(ready.tag, _id(1));
    expect(ready.sessionId, _id(7));
  });

  test('a device that lost drops its answer when the winner is announced', () {
    handle('bob', 'chat.open', callId: _id(7));
    final actions = handle(
      'bob',
      'chat.taken',
      body: {'tag': _id(9)},
      callId: _id(7),
    );
    expect(actions.single, isA<DropSession>());
    // Nothing is left to time out.
    expect(mine.tick(_t0.add(const Duration(minutes: 5))), isEmpty);
  });

  test('an answer that is never decided on is dropped after its timeout', () {
    handle('bob', 'chat.open', callId: _id(7));
    final actions = mine.tick(_t0.add(const Duration(seconds: 20)));
    expect(actions.single, isA<DropSession>());
  });

  test('an offer carrying the winning tag proves the win and is delivered', () {
    handle('bob', 'chat.open', callId: _id(7));
    final actions = handle(
      'bob',
      'chat.offer',
      body: {'tag': _id(1), 'sdp': 'v=0'},
      callId: _id(7),
    );
    expect(actions[0], isA<SessionReady>());
    final signal = actions[1] as DeliverSignal;
    expect(signal.type, 'chat.offer');
    expect(signal.body['sdp'], 'v=0');
  });

  test(
    'connection messages reach only the active session with the right tag',
    () {
      handle('bob', 'chat.open', callId: _id(7));
      handle('bob', 'chat.taken', body: {'tag': _id(1)}, callId: _id(7));

      final ok = handle(
        'bob',
        'chat.ice',
        body: {'tag': _id(1), 'candidate': 'c'},
        callId: _id(7),
      );
      expect(ok.single, isA<DeliverSignal>());

      // Another device's tag: ignored.
      expect(
        handle('bob', 'chat.ice', body: {'tag': _id(9)}, callId: _id(7)),
        isEmpty,
      );
      // Someone who is not the contact: ignored.
      expect(
        handle('eve', 'chat.ice', body: {'tag': _id(1)}, callId: _id(7)),
        isEmpty,
      );
    },
  );

  test('when both open at once, the lower id keeps its invitation', () {
    // mmm < zzz: this device keeps its own open, so the other one is ignored.
    final lower = ChatSignalling(
      myId: 'aaa',
      isContact: (id) => id == 'zzz',
      newId: () => _id(++counter),
    );
    lower.open('zzz', _t0);
    expect(
      lower.handle(
        from: 'zzz',
        type: 'chat.open',
        body: const {},
        callId: _id(8),
        now: _t0,
      ),
      isEmpty,
    );
    expect(lower.isOpening('zzz'), isTrue);
  });

  test(
    'when both open at once, the higher id gives up its own and accepts',
    () {
      final higher = ChatSignalling(
        myId: 'zzz',
        isContact: (id) => id == 'aaa',
        newId: () => _id(++counter),
      );
      higher.open('aaa', _t0);
      final actions = higher.handle(
        from: 'aaa',
        type: 'chat.open',
        body: const {},
        callId: _id(8),
        now: _t0,
      );
      expect(actions.single, isA<SendEnvelope>());
      expect((actions.single as SendEnvelope).type, 'chat.accept');
      expect(higher.isOpening('aaa'), isFalse);
    },
  );

  test('either side can close an active session', () {
    handle('bob', 'chat.open', callId: _id(7));
    handle('bob', 'chat.taken', body: {'tag': _id(1)}, callId: _id(7));

    final closed = mine.close(_id(7));
    expect((closed.single as SendEnvelope).type, 'chat.close');
    expect(mine.close(_id(7)), isEmpty);

    // A new session that the contact closes.
    handle('bob', 'chat.open', callId: _id(8));
    handle('bob', 'chat.taken', body: {'tag': _id(2)}, callId: _id(8));
    final dropped = handle('bob', 'chat.close', callId: _id(8));
    expect(dropped.single, isA<DropSession>());
  });

  test('unknown types and missing session ids do nothing', () {
    expect(handle('bob', 'chat.hello', callId: _id(7)), isEmpty);
    expect(handle('bob', 'chat.open'), isEmpty);
    expect(handle('bob', 'chat.open', callId: 'not-an-id'), isEmpty);
  });
}
