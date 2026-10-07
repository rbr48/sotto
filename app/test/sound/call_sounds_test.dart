import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/call_manager.dart';
import 'package:sotto/sound/call_sounds.dart';

class FakeOutput implements SoundOutput {
  final log = <String>[];
  bool fail = false;

  @override
  Future<void> loop(Sound sound) async {
    log.add('loop ${sound.name}');
    if (fail) throw Exception('no audio device');
  }

  @override
  Future<void> playOnce(Sound sound) async => log.add('once ${sound.name}');

  @override
  Future<void> stopLoop() async => log.add('stop');

  @override
  void dispose() => log.add('dispose');
}

void main() {
  const incoming = CallState(phase: CallPhase.incoming, callId: 'c');

  test('ringtone while ringing here, ringback while ringing there', () {
    final out = FakeOutput();
    final sounds = CallSounds(out);
    sounds.onCallState(incoming, autoAnswered: false);
    sounds.onCallState(incoming, autoAnswered: false); // no restart
    expect(sounds.looping, Sound.ringtone);
    sounds.onCallState(
      incoming.copyWith(phase: CallPhase.connecting),
      autoAnswered: false,
    );
    sounds.onCallState(
      incoming.copyWith(phase: CallPhase.connected),
      autoAnswered: false,
    );

    const outgoing = CallState(
      phase: CallPhase.calling,
      callId: 'd',
      outgoing: true,
    );
    sounds.onCallState(outgoing, autoAnswered: false);
    sounds.onCallState(
      outgoing.copyWith(phase: CallPhase.ringing),
      autoAnswered: false,
    );
    sounds.onCallState(
      outgoing.copyWith(
        phase: CallPhase.ended,
        endReason: CallEndReason.noAnswer,
      ),
      autoAnswered: false,
    );
    expect(out.log, ['loop ringtone', 'stop', 'loop ringback', 'stop']);
    expect(sounds.looping, isNull);
  });

  test('chimes for knocks and auto-answered calls', () {
    final out = FakeOutput();
    final sounds = CallSounds(out);
    sounds.onKnock();
    sounds.onCallState(incoming, autoAnswered: false);
    sounds.onCallState(
      incoming.copyWith(phase: CallPhase.connecting),
      autoAnswered: true,
    );
    expect(out.log, ['once knock', 'loop ringtone', 'stop', 'once answered']);
  });

  test('switched off: nothing plays, loops still stop', () {
    final out = FakeOutput();
    var on = false;
    final sounds = CallSounds(out, enabled: () => on);
    sounds.onCallState(incoming, autoAnswered: false);
    sounds.onKnock();
    expect(out.log, ['stop']);
    on = true;
    sounds.onCallState(
      incoming.copyWith(phase: CallPhase.connected),
      autoAnswered: false,
    );
    sounds.dispose();
    expect(out.log, ['stop', 'stop', 'stop', 'dispose']);
  });

  test('playback errors never reach the call', () async {
    final out = FakeOutput()..fail = true;
    final sounds = CallSounds(out);
    sounds.onCallState(incoming, autoAnswered: false);
    await pumpEventQueue();
    expect(sounds.looping, Sound.ringtone);
  });
}
