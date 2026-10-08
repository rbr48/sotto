import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/call/call_manager.dart';
import 'package:sotto/call/media_engine.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

import 'fakes.dart';

/// A person with a call manager whose messages are delivered straight to
/// the other people's managers (as the relay + envelopes would).
class Person {
  Person(this.name, this.identity, this.network, {this.autoAnswer}) {
    manager = CallManager(
      autoAnswer: (invite) => autoAnswer?.call(invite),
      send: (to, type, body, callId) {
        sent.add(type);
        network.deliver(
          from: this,
          to: to.id,
          type: type,
          body: body,
          callId: callId,
        );
      },
      createMedia: () => media = FakeMediaEngine(),
      newCallId: () => '$name-call-${++_calls}',
      onConnectionTrouble: () => troubles++,
    );
  }

  final String name;
  final Identity identity;
  final Network network;
  AutoAnswer? Function(OpenedMessage invite)? autoAnswer;
  late final CallManager manager;
  FakeMediaEngine? media;
  final sent = <String>[];
  int troubles = 0;
  int _calls = 0;

  PublicIdentity get public => identity.publicIdentity;
  CallPhase get phase => manager.state.phase;
  bool get reconnecting => manager.state.reconnecting;
  CallEndReason? get endReason => manager.state.endReason;
}

class Network {
  final people = <String, Person>{};

  /// Messages to people not in [people] (offline) are dropped.
  void deliver({
    required Person from,
    required String to,
    required String type,
    required Map<String, Object?> body,
    required String callId,
  }) {
    final recipient = people[to];
    if (recipient == null) return;
    recipient.manager.handle(
      OpenedMessage(
        sender: from.public,
        type: type,
        body: Map<String, dynamic>.from(body),
        sentAt: DateTime.now(),
        callId: callId,
      ),
    );
  }
}

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  ({Network network, Person alice, Person bob, Person carol}) setup() {
    final network = Network();
    Person person(String name) {
      final p = Person(name, Identity.generate(sodium), network);
      network.people[p.identity.id] = p;
      return p;
    }

    return (
      network: network,
      alice: person('alice'),
      bob: person('bob'),
      carol: person('carol'),
    );
  }

  test(
    'accepted call: ringing, offer/answer, candidates, connected, hang up',
    () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();

        alice.manager.call(bob.public);
        async.flushMicrotasks();
        expect(alice.phase, CallPhase.ringing);
        expect(bob.phase, CallPhase.incoming);
        expect(bob.manager.state.peer, alice.public);

        bob.manager.accept();
        async.flushMicrotasks();
        expect(alice.phase, CallPhase.connecting);
        expect(bob.phase, CallPhase.connecting);
        expect(alice.media!.log, [
          'prepare(video: true)',
          'createOffer',
          'acceptAnswer(answer-sdp)',
        ]);
        expect(bob.media!.log, [
          'prepare(video: true)',
          'acceptOffer(offer-sdp)',
        ]);

        alice.media!.emitCandidate('a1');
        bob.media!.emitCandidate('b1');
        async.flushMicrotasks();
        expect(bob.media!.log.last, 'addRemoteCandidate(a1)');
        expect(alice.media!.log.last, 'addRemoteCandidate(b1)');

        alice.media!.emitState(MediaConnectionState.connected);
        bob.media!.emitState(MediaConnectionState.connected);
        async.flushMicrotasks();
        expect(alice.phase, CallPhase.connected);
        expect(bob.phase, CallPhase.connected);

        final aliceMedia = alice.media!;
        final bobMedia = bob.media!;
        bob.manager.hangUp();
        async.flushMicrotasks();
        expect(bob.endReason, CallEndReason.hungUp);
        expect(alice.endReason, CallEndReason.remoteHungUp);
        expect(aliceMedia.closed && bobMedia.closed, isTrue);

        // The connect timeout must not fire after the call ended.
        async.elapse(const Duration(minutes: 5));
        expect(alice.endReason, CallEndReason.remoteHungUp);
      });
    },
  );

  test('declined call', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, carol: _) = setup();
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      bob.manager.decline();
      async.flushMicrotasks();
      expect(bob.endReason, CallEndReason.declined);
      expect(alice.endReason, CallEndReason.remoteDeclined);
      expect(bob.media, isNull, reason: 'declining never opens the camera');
    });
  });

  test('caller cancels before an answer: callee sees a missed call', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, carol: _) = setup();
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      alice.manager.hangUp();
      async.flushMicrotasks();
      expect(alice.endReason, CallEndReason.cancelled);
      expect(bob.endReason, CallEndReason.missed);
    });
  });

  test(
    'busy: a third person calling gets busy, the ongoing call is untouched',
    () {
      fakeAsync((async) {
        final (:network, :alice, :bob, :carol) = setup();
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        bob.manager.accept();
        async.flushMicrotasks();

        carol.manager.call(bob.public);
        async.flushMicrotasks();
        expect(carol.endReason, CallEndReason.busy);
        expect(bob.phase, CallPhase.connecting);
        expect(bob.manager.state.peer, alice.public);
      });
    },
  );

  test(
    'no answer: the caller gives up after 45 s and the callee stops ringing',
    () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 44));
        expect(alice.phase, CallPhase.ringing);
        async.elapse(const Duration(seconds: 2));
        expect(alice.endReason, CallEndReason.noAnswer);
        expect(bob.endReason, CallEndReason.missed);
      });
    },
  );

  test('recipient offline: stays "calling" (not ringing), then no answer', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, carol: _) = setup();
      network.people.remove(bob.identity.id);
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      expect(alice.phase, CallPhase.calling);
      async.elapse(const Duration(seconds: 46));
      expect(alice.endReason, CallEndReason.noAnswer);
    });
  });

  test('an incoming call that is never cancelled stops ringing after 60 s', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, carol: _) = setup();
      // Alice's cancel never arrives.
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      network.people.remove(bob.identity.id);
      async.elapse(const Duration(seconds: 61));
      expect(bob.endReason, CallEndReason.missed);
    });
  });

  test(
    'media that never connects fails after 30 s and tells the other side',
    () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        bob.manager.accept();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        expect(
          alice.endReason,
          isIn([CallEndReason.failed, CallEndReason.remoteHungUp]),
        );
        expect(
          bob.endReason,
          isIn([CallEndReason.failed, CallEndReason.remoteHungUp]),
        );
        expect([
          alice.endReason,
          bob.endReason,
        ], contains(CallEndReason.failed));
      });
    },
  );

  test('a media failure ends the call on both sides', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, carol: _) = setup();
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      bob.manager.accept();
      async.flushMicrotasks();
      alice.media!.emitState(MediaConnectionState.failed);
      async.flushMicrotasks();
      expect(alice.endReason, CallEndReason.failed);
      expect(bob.endReason, CallEndReason.remoteHungUp);
    });
  });

  test('no camera: the call fails before anything is sent', () {
    fakeAsync((async) {
      final network = Network();
      final alice = Person('alice', Identity.generate(sodium), network);
      final bob = Person('bob', Identity.generate(sodium), network);
      network.people[bob.identity.id] = bob;
      final manager = CallManager(
        send: (to, type, body, callId) => alice.sent.add(type),
        createMedia: () => FakeMediaEngine()..failPrepare = true,
        newCallId: () => 'x',
      );
      manager.call(bob.public);
      async.flushMicrotasks();
      expect(manager.state.endReason, CallEndReason.failed);
      expect(manager.state.error, contains('Camera or microphone'));
      expect(alice.sent, isEmpty);
      expect(bob.phase, CallPhase.idle);
    });
  });

  test('messages from other people or other calls are ignored', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, :carol) = setup();
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      final callId = alice.manager.state.callId!;

      // Carol pretends to be the callee accepting Alice's call.
      network.deliver(
        from: carol,
        to: alice.identity.id,
        type: 'call.accept',
        body: {},
        callId: callId,
      );
      // Bob sends a reject for a different call.
      network.deliver(
        from: bob,
        to: alice.identity.id,
        type: 'call.reject',
        body: {},
        callId: 'other',
      );
      async.flushMicrotasks();
      expect(alice.phase, CallPhase.ringing);
    });
  });

  test('a duplicated invite does not make the callee busy', () {
    fakeAsync((async) {
      final (:network, :alice, :bob, carol: _) = setup();
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      network.deliver(
        from: alice,
        to: bob.identity.id,
        type: 'call.invite',
        body: {'video': true},
        callId: alice.manager.state.callId!,
      );
      async.flushMicrotasks();
      expect(bob.phase, CallPhase.incoming);
      expect(bob.sent.where((t) => t == 'call.busy'), isEmpty);
    });
  });

  test(
    'voice calls ask for audio only, and a new call can follow an ended one',
    () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        alice.manager.call(bob.public, video: false);
        async.flushMicrotasks();
        expect(bob.manager.state.video, isFalse);
        bob.manager.accept();
        async.flushMicrotasks();
        expect(bob.media!.log.first, 'prepare(video: false)');
        alice.manager.hangUp();
        async.flushMicrotasks();

        alice.manager.dismiss();
        expect(alice.phase, CallPhase.idle);
        bob.manager.call(alice.public);
        async.flushMicrotasks();
        expect(alice.phase, CallPhase.incoming);
      });
    },
  );

  group('auto-answer', () {
    test('answers after the delay; both sides know it was automatic', () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        bob.autoAnswer = (_) =>
            const AutoAnswer(delay: Duration(seconds: 5), video: true);
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 4));
        expect(
          bob.phase,
          CallPhase.incoming,
          reason: 'still ringing during the delay',
        );
        async.elapse(const Duration(seconds: 2));
        expect(bob.phase, CallPhase.connecting);
        expect(bob.manager.state.autoAnswered, isTrue);
        expect(alice.phase, CallPhase.connecting);
        expect(alice.manager.state.autoAnswered, isTrue);
        expect(bob.media!.log, [
          'prepare(video: true)',
          'acceptOffer(offer-sdp)',
        ]);
      });
    });

    test('declining during the delay wins', () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        bob.autoAnswer = (_) =>
            const AutoAnswer(delay: Duration(seconds: 5), video: true);
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        bob.manager.decline();
        async.elapse(const Duration(seconds: 10));
        expect(bob.endReason, CallEndReason.declined);
        expect(alice.endReason, CallEndReason.remoteDeclined);
        expect(bob.media, isNull);
      });
    });

    test(
      'a call that is not auto-answered rings normally and is not flagged',
      () {
        fakeAsync((async) {
          final (:network, :alice, :bob, carol: _) = setup();
          bob.autoAnswer = (_) => null;
          alice.manager.call(bob.public);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 30));
          expect(bob.phase, CallPhase.incoming);
          bob.manager.accept();
          async.flushMicrotasks();
          expect(alice.manager.state.autoAnswered, isFalse);
        });
      },
    );

    test(
      'the decision can use invite extras (e.g. an admitted guest knock)',
      () {
        fakeAsync((async) {
          final (:network, :alice, :bob, carol: _) = setup();
          bob.autoAnswer = (invite) => invite.body['knock'] == 'k1'
              ? const AutoAnswer(delay: Duration.zero, video: true)
              : null;
          alice.manager.call(bob.public, inviteExtras: {'knock': 'k1'});
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          expect(bob.phase, CallPhase.connecting);
        });
      },
    );

    test('auto-answer without video opens only the microphone', () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        bob.autoAnswer = (_) =>
            const AutoAnswer(delay: Duration.zero, video: false);
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(bob.phase, CallPhase.connecting);
        expect(bob.media!.log.first, 'prepare(video: false)');
      });
    });

    test(
      'auto-answer never interrupts an ongoing call (busy still applies)',
      () {
        fakeAsync((async) {
          final (:network, :alice, :bob, :carol) = setup();
          bob.autoAnswer = (_) =>
              const AutoAnswer(delay: Duration.zero, video: true);
          alice.manager.call(bob.public);
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          carol.manager.call(bob.public);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));
          expect(carol.endReason, CallEndReason.busy);
          expect(bob.manager.state.peer, alice.public);
        });
      },
    );
  });

  group('reconnecting a connected call', () {
    /// Alice calls Bob and both connect.
    ({Network network, Person alice, Person bob}) connected(FakeAsync async) {
      final (:network, :alice, :bob, carol: _) = setup();
      alice.manager.call(bob.public);
      async.flushMicrotasks();
      bob.manager.accept();
      async.flushMicrotasks();
      alice.media!.emitState(MediaConnectionState.connected);
      bob.media!.emitState(MediaConnectionState.connected);
      async.flushMicrotasks();
      expect(alice.phase, CallPhase.connected);
      expect(bob.phase, CallPhase.connected);
      alice.media!.log.clear();
      bob.media!.log.clear();
      return (network: network, alice: alice, bob: bob);
    }

    test(
      'both lose the path: the caller restarts ICE and the call goes on',
      () {
        fakeAsync((async) {
          final (network: _, :alice, :bob) = connected(async);
          alice.media!.emitState(MediaConnectionState.disconnected);
          bob.media!.emitState(MediaConnectionState.disconnected);
          async.flushMicrotasks();
          expect(alice.reconnecting && bob.reconnecting, isTrue);
          expect(alice.phase, CallPhase.connected);
          expect(alice.troubles, 1, reason: 'the relay connection is checked');
          expect(alice.media!.log, isEmpty, reason: 'it may recover by itself');

          async.elapse(const Duration(seconds: 2));
          expect(alice.media!.log, [
            'createOffer(iceRestart)',
            'acceptAnswer(answer-to-restart-offer-1)',
          ]);
          expect(bob.media!.log, ['acceptOffer(restart-offer-1)']);
          expect(
            alice.media!.log.where((e) => e.startsWith('createOffer')),
            hasLength(1),
            reason: "Bob's request arrived within a second of Alice's offer",
          );

          alice.media!.emitState(MediaConnectionState.connected);
          bob.media!.emitState(MediaConnectionState.connected);
          async.flushMicrotasks();
          expect(alice.reconnecting || bob.reconnecting, isFalse);

          // No retries or timeouts after recovering.
          async.elapse(const Duration(minutes: 2));
          expect(alice.phase, CallPhase.connected);
          expect(bob.phase, CallPhase.connected);
          expect(alice.media!.log, hasLength(2));
        });
      },
    );

    test('a connection that recovers by itself needs no restart', () {
      fakeAsync((async) {
        final (network: _, :alice, :bob) = connected(async);
        alice.media!.emitState(MediaConnectionState.disconnected);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        alice.media!.emitState(MediaConnectionState.connected);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        expect(alice.reconnecting, isFalse);
        expect(alice.media!.log, isEmpty);
        expect(alice.phase, CallPhase.connected);
      });
    });

    test('only the callee lost it: it asks the caller to restart', () {
      fakeAsync((async) {
        final (network: _, :alice, :bob) = connected(async);
        bob.media!.emitState(MediaConnectionState.failed);
        async.flushMicrotasks();
        expect(bob.reconnecting, isTrue);
        expect(bob.sent.last, 'sdp.answer');
        async.elapse(Duration.zero);
        expect(bob.sent, contains('call.restart'));
        expect(alice.media!.log, [
          'createOffer(iceRestart)',
          'acceptAnswer(answer-to-restart-offer-1)',
        ]);
        expect(alice.reconnecting, isFalse);
        bob.media!.emitState(MediaConnectionState.connected);
        async.flushMicrotasks();
        expect(bob.reconnecting, isFalse);
      });
    });

    test('keeps trying while the other side is unreachable, then gives up', () {
      fakeAsync((async) {
        final (:network, :alice, :bob) = connected(async);
        network.people.remove(bob.identity.id);
        alice.media!.emitState(MediaConnectionState.failed);
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(alice.media!.log, ['createOffer(iceRestart)']);
        async.elapse(const Duration(seconds: 8));
        async.elapse(const Duration(seconds: 8));
        expect(
          alice.media!.log.where((e) => e == 'createOffer(iceRestart)'),
          hasLength(3),
        );
        expect(alice.phase, CallPhase.connected);

        async.elapse(const Duration(seconds: 30));
        expect(alice.phase, CallPhase.ended);
        expect(alice.endReason, CallEndReason.failed);
        expect(alice.manager.state.error, 'Connection lost');
        expect(alice.reconnecting, isFalse);
        expect(alice.sent.last, 'call.end');
      });
    });

    test('networkChanged retries at once; old answers are ignored', () {
      fakeAsync((async) {
        final (:network, :alice, :bob) = connected(async);
        network.people.remove(bob.identity.id);
        alice.media!.emitState(MediaConnectionState.failed);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        alice.manager.networkChanged();
        async.flushMicrotasks();
        expect(
          alice.media!.log.where((e) => e == 'createOffer(iceRestart)'),
          hasLength(2),
        );

        // Bob's answer to the first offer arrives late.
        alice.manager.handle(
          OpenedMessage(
            sender: bob.public,
            type: 'sdp.answer',
            body: {'sdp': 'stale-answer', 'restart': 1},
            sentAt: DateTime.now(),
            callId: alice.manager.state.callId,
          ),
        );
        async.flushMicrotasks();
        expect(alice.media!.log, isNot(contains('acceptAnswer(stale-answer)')));
      });
    });

    test('a call that is still connecting fails as before', () {
      fakeAsync((async) {
        final (:network, :alice, :bob, carol: _) = setup();
        alice.manager.call(bob.public);
        async.flushMicrotasks();
        bob.manager.accept();
        async.flushMicrotasks();
        alice.media!.emitState(MediaConnectionState.failed);
        async.flushMicrotasks();
        expect(alice.endReason, CallEndReason.failed);
        expect(bob.endReason, CallEndReason.remoteHungUp);
      });
    });
  });
}
